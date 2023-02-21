#!/bin/bash

[ -t 1 ] || exec &> >(tee -ai "/tmp/${BASH_SOURCE##*/}-$$")

PROGDIR=`dirname $(readlink --no-newline -e "$BASH_SOURCE")`
BASEDIR=`cd "$PROGDIR"; git rev-parse --show-toplevel || { cd ../; pwd; }`

for f in "${BASEDIR:?}"/tools/.functions{,_aws}; do
  source "$f" || exit
done

[ $EUID -eq 0 ] || { log.warn 'root privileges required'; SUDO='/bin/sudo'; }


declare -A ephemeral=(
  ['i3.xlarge']=/dev/nvme0n1
  ['c5ad.2xlarge']=/dev/nvme2n1
  ['c5d.2xlarge']=/dev/nvme2n1
  ['i4i.large']=/dev/nvme2n1
  ['default']=/dev/nvme1n1
)

# NOTE values vary on Kernel version; try sed 's/^sd/xvd/1'
declare -A ebsdev=(
  ['default']=/dev/xvdf
)

declare -A origin=(
  ['device']=
  ['lvm']=misc/maps
  ['cache']=cache0
  ['mount_point']=/home/XXX/config/docker/maps
  ['path_prefix']=
  ['bucket']=comsearch.maps
  ['bucket_prefix']=
)

declare -A map_snapshot=(
  ['us-east-1']=snap-008cf88dbbb19ea8b
  ['us-east-2']=
)

declare -A disksize=(
  ['profile_GDAL']=22500
  ['terrain']=842396000
  ['nlcd']=43279000
  # >= 863,288,426,496
  ['device']=865000000000
)

declare -A my=(
  ['az']=`ec2.metadata availability-zone`
  ['region']=`ec2.metadata region`
  ['self']=`ec2.metadata self`
  ['type']=`ec2.metadata type`
)

declare -A myTags=(
  ['Billing']=`aws.get ec2.tag "${my[self]}" Billing`
)


function copy_s3() {
  __AWS s3 sync --exact-timestamps ${VERBOSE:- --no-progress} ${QUIET:+ --only-show-errors} "$@"
}

function copy_local() { rsync -a "$@"; }

function vol_search() {
  __AWS ec2 describe-volumes --filters \
      Name=snapshot-id,Values=${SNAPSHOT:-$1} \
      Name=status,Values=available \
      Name=volume-type,Values=gp3 \
      Name=availability-zone,Values=${my['az']}
}

function vol_create() {
  __AWS ec2 create-volume --snapshot-id ${SNAPSHOT:-$1} \
      --volume-type gp3 --availability-zone ${my['az']} \
      --tag-specifications ResourceType=volume,Tags=[{Key=Billing,Value=${myTags['Billing']}}]
}

function vol_attach() {
  __AWS ec2 attach-volume --volume-id ${VOLUME:-$1} --device $DEVICE --instance-id ${my['self']}
}

function is_attached() {
  read name size item < <(
      lsblk --nodeps --list --noheadings --bytes --output 'NAME,SIZE,TYPE' "${DEVICE:?}"
    ) || return

  [[ ${item:?} =~ disk|lvm && ${size:-0} -ge ${SIZE:-${disksize['device']}} ]]
}

function is_mounted() {
  local output=`lsblk --list --noheadings --output 'MOUNTPOINT' "${DEVICE:?}"`

  [ "${MOUNTPOINT:?}" = "$output" ]
  #alt:  awk -v dev=${DEVICE:-${origin['device']}} '$1 == dev { print $2; }' /proc/mounts
}

function is_populated() {
  local path="${MOUNTPOINT:?}/${origin['path_prefix']}"
  local -i limit=30000000000

  (
  cd "$path" || return
  for dir in "${!disksize[@]}"; do    # keys() not supported by Bash 4.2.46
    [[ $dir =~ device ]] && continue

    local -i spec=${disksize[$dir]} size=
    # VERY slow if non-expanded EBS volume
    [ $spec -gt $limit -a $SLOW_COPY -eq 1 ] || continue

    size=`du -sx "$dir" | awk '{ print $1 }'`
    [ $spec -gt 0 -a $size -gt 0 -a $size -ge $spec ] || {
        log.error "invalid disk contents ($path/$dir: $size < $spec)"
        return
      }
  done
  )
}


#---- MAIN ----

${TRACE:+set -x}

: ${DEVICE:=${ebsdev[${my['type']}]:-${ebsdev['default']}}}
: ${MOUNTPOINT:=${origin['mount_point']}}
: ${SNAPSHOT:=`aws.get ec2.tag "${my[self]}" terrain.maps`}
: ${SNAPSHOT:=${map_snapshot[${my['region']}]}}
: ${SLOW_COPY:=0}
declare -i loop=1

while ! is_attached; do
  [ $loop -le 2 ] || { log.error 'create+attach volume failed - too many attempts'; exit; }

  declare -a volumes=( `vol_search | __JQR '.Volumes[].VolumeId'` )
  vol_id=${volumes[0]}

  if [ -z "$vol_id" ]; then
    log.info "($loop) creating volume from snapshot ..."
    vol_id=`vol_create | __JQR '.VolumeId'`
    [ -n "$vol_id" ] || { log.error 'create volume failed'; continue; }

    for i in 8 8 16 24; do
      sleep $i
      volume_status=`aws.describe volume-status "$vol_id"`
      [ 'ok' = "$volume_status" ] && break
    done
    [ 'ok' = "$volume_status" ] || {
        log.warn "($loop) timeout - volume status ('ok' != $volume_status)"
        continue
      }
  fi

  log.info "($loop) attaching volume ${vol_id} ..."
  vol_attach "$vol_id"

  for i in 8 8 16 24; do
    sleep $i
    volume_attach=`aws.describe volume-attachment "$vol_id" | __JQR '.State'`
    [ 'attached' = "$volume_attach" ] && break
  done
  [ 'attached' = "$volume_attach" ] ||
      log.warn "($loop) timeout - volume attach ('attached' != $volume_attach)"

  loop+=1
done


${SUDO} lvscan
# LV with missing PV (eg. cache) doesn't show except via lvs
if lsblk --noheadings --output 'TYPE' "$DEVICE" | grep -q lvm ||
    ${SUDO} lvs "${origin['lvm']}" &>/dev/null; then

  USE_LVM=1
  vg=${origin['lvm']%%/*}
  lv=${origin['lvm']#*/}

  # clean up from 'warm pool' or recycling
  loop=1
  while ! $SUDO lvchange -a y "${origin['lvm']}"; do
    [ $loop -le 2 ] || { log.error 'activate LVM failed - too many attempts'; exit; }

    ${DEBUG:+ runv} $SUDO lvremove "$vg/${origin['cache']}"
    ${DEBUG:+ runv} $SUDO vgreduce "$vg" --removemissing

    loop+=1
  done

  origin['device']=/dev/mapper/"${vg}-${lv}"
  DEVICE=${origin['device']}
fi

# preceeding may result in automatic mount. 32 means 'already mounted'
$SUDO mount ${DEBUG:+ -v} "$DEVICE" "$MOUNTPOINT" || [ $? -eq 32 ]

loop=1
while ! is_populated; do
  # WARN not compatible with auto-scaling
  [ ${SLOW_COPY} -eq 1 ] || exit
  [ $loop -le 2 ] || { log.error 'populating volume failed - too many attempts'; exit; }

  log.info "(SLOW_COPY.$loop) populating from origin (s3://${origin['bucket']}) ..."
  $SUDO mount ${DEBUG:+ -v} -o rw,remount "$DEVICE"
  copy_s3 "s3://${origin['bucket']}/${origin['bucket_prefix']}" \
      "$MOUNTPOINT/${origin['path_prefix']}"
  $SUDO mount ${DEBUG:+ -v} -o ro,remount "$DEVICE"

  loop+=1
done


#--- crude 2-pass invocation ---
[ ${MAP_CACHE:-0} -eq 1 ] || exit 0


set -e

: ${SSD_DEVICE:=${ephemeral[${my['type']}]:-${ephemeral['default']}}}

# thick copy (deprecated)
if [ ${SLOW_COPY} -eq 1 ]; then
  DEVICE=${SSD_DEVICE:?} is_attached ||
      log.error "(SLOW_COPY) cache disk missing/too small ($SSD_DEVICE)"

  $SUDO tune2fs -l "$SSD_DEVICE" &>/dev/null || mkfs -t ext4 "$SSD_DEVICE"
  $SUDO mount ${VERBOSE:+ -v} "$SSD_DEVICE" /mnt

  loop=1
  while ! MOUNTPOINT=/mnt is_populated; do
    [ $loop -le 2 ] || log.error '(SLOW_COPY) failed, too many attempts'

    log.info '(SLOW_COPY) populating cache ...'
    ${DEBUG:+ runv} copy_local "$MOUNTPOINT/" /mnt/

    loop+=1
  done

  $SUDO umount /mnt
  # overlay origin with SSD_DEVICE
  $SUDO mount ${VERBOSE:+ -v} -o ro "$SSD_DEVICE" "$MOUNTPOINT"

# LVM-cache
elif [ ${USE_LVM:-0} -eq 1 ]; then
  DEVICE=${SSD_DEVICE:?} SIZE=$(( ${disksize['device']} / 10 )) is_attached || {
      log.warn "cache disk missing/too small ($SSD_DEVICE)"
      exit 0
    }

  vg=${origin['lvm']%%/*}
  lv=${origin['lvm']#*/}

  ${DEBUG:+ runv} $SUDO pvcreate "$SSD_DEVICE"
  ${DEBUG:+ runv} $SUDO vgextend "${vg:?}" "$SSD_DEVICE"
  ${DEBUG:+ runv} $SUDO lvcreate --type cache -l 99%PVS \
      -n "${origin['cache']}" "${origin['lvm']}" "$SSD_DEVICE"
fi


# vim: expandtab:ts=4:sw=2
