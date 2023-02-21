#!/bin/bash
# use ONLY on Amazon EC2 and project XXX

[ -t 1 ] || exec &> >( tee -ai "/tmp/${BASH_SOURCE##*/}-$$" )

PROGDIR=`dirname $(readlink --no-newline -e "$BASH_SOURCE")`
BASEDIR=`cd "$PROGDIR"; git rev-parse --show-toplevel || { cd ../; pwd; }`

for f in "${BASEDIR:?}"/tools/.functions{,_aws}; do
  source "$f" || exit
done


[ $EUID -eq 0 ] || { log.notice "root privileges required"; SUDO='/bin/sudo'; }
# when running under cloud-init, key SHELL variables are not initialized
: ${HOME:=/root}
export HOME

declare -A tags=(
  ['service']='container.service'
  ['parameter_path']='ssm.parameter_path'
  ['stack_name']='stack'
  ['stack_id']='cloudformation.stack_id'
  ['repo_url']='repo.url'
  ['repo_user']='repo.user'
  ['repo_name']='repo.name'
  ['repo_branch']='repo.branch'
)


#---- main ----
set -e
${TRACE:+set -x}

region=`ec2.metadata region`
export AWS_DEFAULT_REGION=${region:?}
# JAVA SDK does not support _DEFAULT_
export AWS_REGION=${region:?}

instance_id=`ec2.metadata self`
vpc_id=`ec2.metadata vpc-id`
account_id=`aws.get sts.account`
stack=`aws.get ec2.tag "${instance_id:?}" "${tags['stack_name']}"`
# fallback
: ${stack:=${vpc_id#vpc-}}

ssm_parameter_path=`aws.get ec2.tag "$instance_id" "${tags['parameter_path']}"`
# fallback
: ${ssm_parameter_path:=/${stack:?}}

# pseudo-recursion to self-update
if [ ${git_done:-0} -eq 1 ]; then
  :
else
( cd "$BASEDIR"
  set +e

  : ${REPO_NAME:=`aws.get ec2.tag "$instance_id" "${tags['repo_name']}"`}
  # fallback
  : ${REPO_NAME:=`basename -s .git $(git config --get remote.origin.url)`}

  git_url=`aws.get ec2.tag "$instance_id" "${tags['repo_url']}"`
  : ${git_url:=`aws.get ssm.parameter "$ssm_parameter_path/repos/$REPO_NAME/url"`}
  [ -n "$git_url" ] &&
      git config --global credential.${git_url}.helper store

  git_user=`aws.get ec2.tag "$instance_id" "${tags['repo_user']}"`
  : ${git_user:=`aws.get ssm.parameter "$ssm_parameter_path/repos/$REPO_NAME/user"`}
  [ -n "$git_user" ] &&
      git config --global "credential.${git_url}.username" "$git_user"

  #TODO construct from elements and urlencode() passwd
  git_creds=`aws.get ssm.parameter "$ssm_parameter_path/repos/$REPO_NAME/credentials"`
  [ -n "$git_creds" ] &&
      echo "$git_creds" > ~/.git-credentials

  git_branch=`aws.get ec2.tag "$instance_id" "${tags['repo_branch']}"`
  : ${git_branch:=`aws.get ssm.parameter "$ssm_parameter_path/repos/$REPO_NAME/branch"`}

  set -e  
  $SUDO git fetch --quiet
  $SUDO git checkout "${git_branch:-$stack}"
  $SUDO git pull --quiet || { $SUDO git reset --hard && $SUDO git pull; }
)

  exec env git_done=1 "$BASH_SOURCE"
  exit      # not reached?
fi

#TODO break-out into services.sh
$SUDO systemctl daemon-reload
$SUDO systemctl enable ntpd
$SUDO systemctl restart ntpd
( set +e
  $SUDO systemctl stop rpcbind
  $SUDO systemctl disable rpcbind
  [[ "$systemd_unit" =~ postfix ]] || {
      $SUDO systemctl stop postfix
      $SUDO systemctl disable postfix
    }
)

: ${DOCKER_DIR:=$BASEDIR/docker}
( cd "$DOCKER_DIR"

  cp -uv daemon.json /etc/docker/ || true
  systemctl restart docker.service

  source create_cloud-env
  source create_dynamic-env
)


systemd_unit=`aws.get ec2.tag "${instance_id:?}" "${tags[service]}"`
: ${systemd_unit:?}
# catch non-qualified case
[ "${systemd_unit%/*}" = "${systemd_unit##*/}" ] &&
    : ${SYSTEMD_DIR:=$BASEDIR/systemd} ||
    SYSTEMD_DIR=${systemd_unit%/*}
systemd_unit=${systemd_unit##*/}
readlink -ve "$SYSTEMD_DIR/$systemd_unit"


#TODO break out to provision-terrain.sh
if [[ "$systemd_unit" =~ terrain ]]; then
  file=/etc/sudoers.d/XXX
  cat > "$file" << _EOF
XXX    ALL=(ALL)   NOPASSWD: /sbin/pv*, /sbin/vg*, /sbin/lv*, /usr/bin/mount, /usr/bin/umount
_EOF
  ${DEBUG:+ runv} $SUDO chmod 440 "$file"
fi

log.info "define and enable service(s)"
${DEBUG:+ runv} $SUDO systemctl link "$SYSTEMD_DIR/terminate.service"
${DEBUG:+ runv} $SUDO systemctl enable "$SYSTEMD_DIR/$systemd_unit"
${DEBUG:+ runv} $SUDO systemctl start "$systemd_unit"

if [[ "$systemd_unit" =~ terrain ]]; then
  log.info "provision Terrain tile cache"
  # failure can be ignored
  ${DEBUG:+ runv} env MAP_CACHE=1 $PROGDIR/copy-maps.sh || true
fi


# vim: expandtab:ts=4:sw=2
