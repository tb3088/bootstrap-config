#!/bin/bash

ecr_region=`cut -d . -f 4 <<< "$IMAGE_URL"`

aws ecr get-login-password ${ecr_region:+ --region $ecr_region} |
    docker login --password-stdin --username AWS ${IMAGE_URL:-${ACCOUNT_ID:?}.dkr.ecr.${AWS_DEFAULT_REGION:?}.amazonaws.com}

# deprecated
#eval `aws ecr get-login --no-include-email`
