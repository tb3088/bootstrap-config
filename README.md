# Introduction
The scripts allow an EC2 instance to bootstrap itself into a fully operational
node of multiple flavors using just TAGs or SSM Parameter Store values. 
The key hierarchy must drive the `tools/create_dynamic-env` scriptlet.
Standardizing on an attribute pattern (eg. Ansible or Puppet facter) is recommended.

This example pulls 1 of 4 different Docker container images and wires up the applicable SystemD service.
The node was created in response to Cloudwatch metric-based alarms that incremented an AWS 
Autoscaling-Group with associated launch template. Invoke `tools/bootstrap.sh` from UserData. 

Multiple environments are just Git branches.


## AMI
*NOTE* There are instances of `XXX` scattered throughtout that need to addressed before use.

The following tools are required:
- git
- AWS Cli (Python3, boto3)

Depending on the system functionality add:
- Docker Engine, [Compose](https://github.com/docker/compose)
- LVM tools
- Puppet [facter](https://github.com/puppetlabs/facter)

My experience with `login.gov` and `GSA/18f` group showed there needs to be a balance between using pre-baked
or stock AMIs. This example benefits from an existing (if obsolete) checkout, and sufficient rights via `sudo`
and IAM instance-role. If repo access (readonly) needs credentials, they should be injected dynamically
via environment.

**!! NEVER BAKE CREDENTIALS INTO AMIs !!**
