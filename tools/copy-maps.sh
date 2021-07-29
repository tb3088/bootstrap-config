#!/bin/bash

[ -t 1 ] || exec &> >(tee -ai "/tmp/${BASH_SOURCE##*/}-$$")

prog=`readlink -e $BASH_SOURCE`
PROG=`dirname "$prog"`
for i in "$PROG"/.functions{,_aws}; do
  source "$i" || exit
done

[ $EUID -eq 0 ] || { log.warn 'root privileges required'; SUDO='/bin/sudo'; }


declare -A ephemeral=(
  [i3.xlarge]=/dev/nvme0n1
#  [m5d.xlarge]=
#  [r5d.xlarge]=
)

# NOTE values vary on Kernel version; try sed 's/^sd/xvd/1'
declare -A osdev=(
  [i3.xlarge]=/dev/xvdf
#  [m5d.xlarge]=
#  [r5d.xlarge]=
)

declare -A origin=(
  [device]=/dev/mapper/misc-maps
  [lvm]=misc/maps
  [path]=/home/lego/lego-config/docker/maps
  [bucket]=maps
  [snapshot]=snap-XXXXX
)

declare -A disksize=(
  [profile_GDAL]=22564
  [terrain]=842396232
  [device]=865000000000
)

declare -A my=(
  [az]=`ec2.metadata availability-zone`
  [self]=`ec2.metadata self`
  [type]=`ec2.metadata type`
)

declare -A myTags=(
  [Billing]=`aws.get ec2.tag ${my[self]} Billing`
)

declare -A cmd=(
  [copy_s3]="$AWS s3 sync --exact-timestamps ${VERBOSE:- --no-progress} ${QUIET:+ --only-show-errors}"
  [copy_local]='rsync -a'

  [vol_search]="$AWS ec2 describe-volumes --filters
        Name=snapshot-id,Values=${SNAPSHOT:-${origin[snapshot]}}
        Name=status,Values=available
        Name=availability-zone,Values=${my[az]}"

  [vol_create]="$AWS ec2 create-volume
        --availability-zone ${my[az]}
        --snapshot-id ${SNAPSHOT:-${origin[snapshot]}}
        --volume-type gp2
        --tag-specifications 'ResourceType=volume,Tags=[{Key=Billing,Value=${myTags[Billing]}}]'"

  [vol_attach]="$AWS ec2 attach-volume
        --device ${DEVICE:-${osdev[${my[type]}]}}
        --instance-id ${INSTANCE_ID:-${my[self]}}"
)


function is_attached {
  read device size rest < <(
      lsblk -alpnb -o NAME,SIZE,TYPE,MOUNTPOINT |
          awk -v device="${origin[device]}" '$1 == device { print }'
    )
  # >= 863,288,426,496
  [ ${size:-0} -ge ${disksize[device]} ]
}


function is_mounted {
  local device

  [ "`awk -v dev=${device:-${origin[device]}} '$1 == dev { print $2; }' /proc/mounts`" = "${origin[path]}" ]
}


function is_populated {
  local path
  : ${path:=${origin[path]}}

  [ -d "$path/profile_GDAL" -a -d "$path/terrain" ] || return

  [ `du -sx "$path/profile_GDAL" | awk '{ print $1 }'` -ge ${disksize[profile_GDAL]} -a \
    `du -sx "$path/terrain" | awk '{ print $1 }'` -ge ${disksize[terrain]} ]
}


# gratuitous
$SUDO lvscan

if ! is_attached; then
  # WARN - previously mounted (LVM-cached) volumes can NOT be used !!

  log.info "creating volume from ${origin[snapshot]} ..."
  vol_id=`${cmd[vol_create]} | $JQR '.VolumeId //empty'` || log.error "create volume"
  for i in 8 8 16 24; do
    sleep $i
    [ `aws.describe volume-status $vol_id` = 'ok' ] && break
  done

  ${DEBUG:+ runv} ${cmd[vol_attach]} --volume-id ${vol_id:?} >/dev/null || log.error "attach volume"
  for i in 8 8 16 24; do
    sleep $i
    [ `aws.describe volume-attachment $vol_id | $JQR '.State'` = 'attached' ] && break
  done

  $SUDO lvscan
fi

#TODO not useful, need 'active' check and no PV exclusion
#  ACTIVE            '/dev/misc/maps' [1.07 TiB] inherit
#$SUDO lvdisplay --select lv_dm_path=${origin[device]}

is_mounted || $SUDO mount ${DEBUG:+ -v} ${origin[device]} ||
    log.error "mount volume"

if ! is_populated; then
  log.warn "invalid contents - populating from origin (s3://${origin[bucket]}) ..."
  # WARN takes several hours and not suitable for autoscaling-group
  [ ${SLOW_COPY:-0} -eq 1 ] || { log.warn 'skipped (SLOW_COPY != 1)'; exit 1; }

  touch ${origin[path]}/.write-test ||
      $SUDO mount ${DEBUG:+ -v} -o rw,remount ${origin[device]}

  ${DEBUG:+ runv} ${cmd[copy_s3]} s3://${origin[bucket]} ${origin[path]} &&
      is_populated || log.error "copy incomplete/failed"

  $SUDO mount ${DEBUG:+ -v} -o ro,remount ${origin[device]}
fi


# crude 2-pass invocation
[ "${MAP_CACHE:-0}" -eq 1 ] || exit 0


# ephemerial SSD defined?
[ -n "${SSD_DEVICE:=${ephemeral[${my[type]}]}}" ] || {
    log.notice "no ephemeral device defined"
    exit 0
  }

read size mountpoint < <( lsblk -alpnb -o SIZE,MOUNTPOINT $SSD_DEVICE )

# deprecated non-LVM style
if device=$SSD_DEVICE is_mounted && is_populated; then
  log.notice "$SSD_DEVICE already mounted"
  exit 0
fi

if [ ${size:-0} -ge ${disksize[device]} -a ${SLOW_COPY:-0} -eq 1 ]; then
  # do full copy (> 863,288,426,496)

  $SUDO tune2fs -l $SSD_DEVICE &>/dev/null || mkfs -t ext4 $SSD_DEVICE
  $SUDO mount ${VERBOSE:+ -v} $SSD_DEVICE /mnt

  if ! path=/mnt is_populated; then
    log.info "populating cache ..."
    ${DEBUG:+ runv} ${cmd[copy_local]} ${origin[path]}/ /mnt/ &&
        path=/mnt is_populated || log.error "copy incomplete/failed"
  fi
  $SUDO umount /mnt

  # overlay SSD
  $SUDO mount ${VERBOSE:+ -v} -o ro $SSD_DEVICE ${origin[path]}

  # special return value to trigger container restart logic in caller
  exit 128

else    # use LVM cache
  vg=${origin[lvm]%/*}
  lv=${origin[lvm]##*/}

  set -e

  ${DEBUG:+ runv} $SUDO pvcreate $SSD_DEVICE
  ${DEBUG:+ runv} $SUDO vgextend ${vg:?} $SSD_DEVICE
  ${DEBUG:+ runv} $SUDO lvcreate --type cache -l 99%PVS -n cache0 $vg/${lv:?} $SSD_DEVICE
fi

# vim: expandtab:ts=4:sw=2
