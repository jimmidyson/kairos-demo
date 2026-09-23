#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 7 "clusterctl init CAPX + CAAPH + in-place helper" \
  "KIND becomes the CAPI management cluster." \
  "namespaces capi-system, capx-system, caaph-system"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
export NUTANIX_ENDPOINT NUTANIX_USER NUTANIX_PASSWORD
export NUTANIX_PRISM_ELEMENT_CLUSTER_NAME NUTANIX_SUBNET_NAME
export NUTANIX_SSH_AUTHORIZED_KEY CONTROL_PLANE_ENDPOINT_IP
export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME="${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64}"

clusterctl init --infrastructure nutanix --addon helm

# In-place helper binary on the management workstation; CAPI Runtime SDK
# ExtensionConfig can point at a later Deployment of this image.
mkdir -p "${ROOT}/build"
( cd "${ROOT}/extension" && go build -o "${ROOT}/build/inplace-extension" ./cmd/inplace-extension )

step_ok
next_step 8
