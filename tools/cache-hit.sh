#!/bin/bash

read tot_r act_r <<< `cat /proc/${1:?}/io | awk '$1 == "rchar:" { print $2 }; $1 == "read_bytes:" { print $2 }'`

echo "READ cache hit:" `bc <<< "scale=2; (1 - $act_r / $tot_r)"`

