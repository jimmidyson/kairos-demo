#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=prism.sh
source "${ROOT}/scripts/prism.sh"

IMAGE_NAME="${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64}"

step_start 10 "Destroy CAPX cluster" \
  "Delete the workload Cluster and the Prism image. The management cluster stays unless DESTROY_KIND=1." \
  "Cluster kairos-capi, Prism image ${IMAGE_NAME}"

export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
if kubectl get cluster kairos-capi >/dev/null 2>&1; then
  kubectl delete cluster kairos-capi --wait=true
fi

if [[ "${DESTROY_PRISM:-1}" != "0" ]]; then
  require_env NUTANIX_ENDPOINT
  require_env NUTANIX_USER
  require_env NUTANIX_PASSWORD
  prism_delete_image "${IMAGE_NAME}"
fi

if [[ "${DESTROY_KIND:-}" == "1" ]]; then
  mgmt_delete "${KAIROS_KIND_CLUSTER_NAME}"
fi
step_ok
