#!/bin/bash -e

[ -t 1 ] || exec &> >(tee -ai "/tmp/${BASH_SOURCE##*/}-$$")

PROGDIR=`dirname $(readlink -e "$BASH_SOURCE")`
BASEDIR=`git rev-parse --show-toplevel` || ( cd "$PROGDIR"/../..; pwd )

for f in "$BASEDIR"/tools/.functions{,_aws}; do
  source "$f"
done
#[ -f "$BASEDIR"/env ] && source "$BASEDIR"/env

instance_id=`ec2.metadata self`

__AWS autoscaling set-instance-health \
    --instance-id ${instance_id:?} \
    --health-status Unhealthy \
    --no-should-respect-grace-period

sleep 60

__AWS terminate-instance-in-auto-scaling-group \
    --instance-id ${instance_id:?} \
    --no-should-decrement-desired-capacity


# vim: expandtab:ts=8:sw=4
