#!/bin/bash
#
# use ONLY on Amazon EC2

[ -t 1 ] || exec &> >(tee -ai "/tmp/${BASH_SOURCE##*/}-$$")

prog=`readlink -e $BASH_SOURCE`
PROG=`dirname "$prog"`
for i in "$PROG/.functions"{,_aws}; do
  source "$i" || exit
done

[ $EUID -eq 0 ] || { log.warn "root privileges required"; SUDO='/bin/sudo'; }
# when running under cloud-init, key SHELL variables are not initialized
export HOME=${HOME:-/root}

: ${BASE_DIR:=`cd $PROG/..; pwd`}
[ -d "$BASE_DIR" ] || exit


# endpoint variables and constants
: ${REPO_PATH:=repos}
: ${REPO_NAME:=bootstrap-config}

declare -A tags=(
  [service]=container.service
  [parameter_path]=ssm.parameter_path
  [stack_name]=stack
  [stack_id]=cloudformation.stack_id
  [billing]=Billing
)


# NOTICE no changes below
#------------------------

region=`ec2.metadata region`
export AWS_DEFAULT_REGION=${region:?}

instance_id=`ec2.metadata self`
vpc_id=`ec2.metadata vpc-id`
account_id=`aws.get sts.account`
stack=`aws.get ec2.tag ${instance_id:?} ${tags[stack_name]}`
# fallback
: ${stack:=${vpc_id#vpc-}}

ssm_parameter_path=`aws.get ec2.tag ${instance_id:?} ${tags[parameter_path]}`
# fallback
: ${ssm_parameter_path:=/${stack:?}}

git_url=`aws.get ssm.parameter "$ssm_parameter_path/${REPO_PATH:?}/${REPO_NAME:?}/url"`
git config --global credential.${git_url:?}.username `aws.get ssm.parameter "$ssm_parameter_path/$REPO_PATH/$REPO_NAME/user"`
git config --global credential.${git_url}.helper store
#TODO construct from elements and urlencode() passwd
aws.get ssm.parameter "$ssm_parameter_path/$REPO_PATH/$REPO_NAME/credentials" > ~/.git-credentials

# use pseudo-recursion to self-update
[ ${RECURSE:-0} -eq 1 ] || { 
    ( cd "$BASE_DIR"
      $SUDO git fetch
      $SUDO git checkout "${stack:?}"
      $SUDO git pull || { $SUDO git reset --hard && $SUDO git pull; }
    )

    $SUDO systemctl daemon-reload
    exec env RECURSE=1 $BASH_SOURCE
  }

systemctl enable ntpd; systemctl restart ntpd

source "$PROG/create-cloud.env"
source "$PROG/create-dynamic.env"

systemd_unit=`aws.get ec2.tag ${instance_id:?} ${tags[service]}`
: ${systemd_unit:?}
: ${SYSTEMD_DIR:=${systemd_unit%/*}}
systemd_unit=${systemd_unit##*/}

[ "$SYSTEMD_DIR" != "$systemd_unit" ] || SYSTEMD_DIR="$BASE_DIR/systemd"
[ -d "$SYSTEMD_DIR" ] || log.error "invalid path ($SYSTEMD_DIR)"

if [[ "$systemd_unit" =~ terrain ]]; then
  # create and/or attach map volume
  ${DEBUG:+ runv} $PROG/copy-maps.sh || exit
fi

${DEBUG:+ runv} $SUDO systemctl enable "$SYSTEMD_DIR/$systemd_unit"
${DEBUG:+ runv} $SUDO systemctl start "$systemd_unit" || exit

# all other types finished
[[ "$systemd_unit" =~ terrain ]] || exit 0


# --- Terrain only ---

# setup map cache
${DEBUG:+ runv} env MAP_CACHE=1 $PROG/copy-maps.sh

# trigger safe container restart
[ $? -eq 128 ] || exit 0


# deprecated

#FIXME detect TG from 'describe-targets' call
target_group=${TARGET_GROUP:-terrain-$stack-int}
target_group_arn=`aws.describe target-group ${target_group:?} | $JQR '.TargetGroupArn'`

#TODO could be multiple assignment
${DEBUG:+ runv} $AWS elbv2 deregister-targets \
    --target-group-arn ${target_group_arn:?} \
    --targets Id=$instance_id

${DEBUG:+ runv} $AWS elbv2 wait target-deregistered \
    --target-group-arn ${target_group_arn:?} \
    --targets Id=$instance_id

# fail after 40 attempts at 15 second intervals
# ref: https://docs.aws.amazon.com/cli/latest/reference/elbv2/wait/target-deregistered.html
[ $? -eq 255 ] &&
    log.error "TargetGroup deregister timed out ($instance_id, $target_group)"

${DEBUG:+ runv} $SUDO systemctl restart "$systemd_unit" || exit

${DEBUG:+ runv} $AWS elbv2 register-targets \
    --target-group-arn $target_group_arn \
    --targets Id=$instance_id

# vim: expandtab:ts=4:sw=2
