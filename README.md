# Introduction
The scripts allow an EC2 instance with a modestly generic AMI to bootstrap itself into a fully operational
node using just TAGs or SSM Parameter Store values. The key hierarchy must drive the `tools/create_dynamic-env` 
scriptlet. Standardizing on an attribute pattern (eg. Ansible or Puppet facter) is recommended.

This example pulls 1 of 4 different Docker container images and wires up the applicable SystemD service.
The node was created in response to Cloudwatch metric-based alarms that incremented an AWS 
Autoscaling-Group and its associated Launch-Template where `tools/bootstrap.sh` is invoked from the 
customary Cloud-Init stanza. 

Multiple environments are just Git branches.

## AMI
The following tools are required:
- git
- AWS Cli (Python3, boto3)

Depending on the role add:
- Docker Engine, [Compose](https://github.com/docker/compose)
- LVM tools
- Puppet [facter](https://github.com/puppetlabs/facter)

My experience with `login.gov` and `GSA/18f` group showed there needs to be a balance between pre-baked
and stock AMIs. This example assumes an existing (if obsolete) checkout, and sufficient rights via `sudo`
if not running as privileged.

*NOTE* There are instances of `XXX` scattered throughtout that need to addressed before use.
