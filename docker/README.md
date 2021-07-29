# Common
All application logging goes to AWS Cloudwatch.
WARN: the log group must PRE-exist before launch. Docker is too stupid to attempt creation.

GC logging is retained in container's volume. It can be accessed via:
    docker-compose ... exec <service> tail -f <file>

Docker is unable to process token substitution (eg. "${VAR}") except in launch template. Said variables *MUST ONLY* be defined in '.env' file or in environment PRIOR to Docker invocation. Any ```env_file``` (eg. 'common.env') must contain *ONLY* static values since no dereferencing is attempted. Neither can their contents be referenced in the launch template.

"ports" doesn't permit variable expansion, so be explicit

## Network Addressing
For any kind of off-VPC networking (eg. VPC peering) the default Docker subnets may well clash with the peer. Use '--default-address-pool base=172.16.0.0/20,size=24' or stanza in docker/daemon.json:

"default-address-pools" : [
    {
      "base" : "172.31.0.0/16",
      "size" : 24
    }
  ]

Otherwise a spec can be embedded into the compose.yaml:
#ref https://docs.docker.com/compose/compose-file/compose-file-v2/#network-configuration-reference
networks:
  default:
    ipam:
      config:
        - subnet: 192.168.17.0/24


# Frontend

# Backend

