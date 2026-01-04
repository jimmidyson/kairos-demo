#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly ISO_PATH="$SCRIPT_DIR/build/bootstrap.iso"

if [ ! -f "$ISO_PATH" ]; then
  echo "ISO file not found: $ISO_PATH"
  exit 1
fi

export TF_VAR_iso_file="$ISO_PATH"

if [ -z "$NUTANIX_USERNAME" ]; then
  echo "NUTANIX_USERNAME is not set"
  exit 1
fi

if [ -z "$NUTANIX_PASSWORD" ]; then
  echo "NUTANIX_PASSWORD is not set"
  exit 1
fi

export TF_VAR_cluster_name=${NUTANIX_CLUSTER}
if [ -z "$TF_VAR_cluster_name" ]; then
  echo "NUTANIX_CLUSTER is not set"
  exit 1
fi
export TF_VAR_subnet_name=${NUTANIX_SUBNET}
if [ -z "$TF_VAR_subnet_name" ]; then
  echo "NUTANIX_SUBNET is not set"
  exit 1
fi

tofu -chdir="$SCRIPT_DIR/terraform" apply -auto-approve