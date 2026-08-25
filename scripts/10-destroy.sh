#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 10 "Destroy CAPX cluster" \
  "Delete the workload Cluster. KIND is left unless DESTROY_KIND=1." \
  "Cluster kairos-capi, optional KIND ${KAIROS_KIND_CLUSTER_NAME}"

export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
if kubectl get cluster kairos-capi >/dev/null 2>&1; then
  kubectl delete cluster kairos-capi --wait=true
fi
if [[ "${DESTROY_KIND:-}" == "1" ]]; then
  kind delete cluster --name "${KAIROS_KIND_CLUSTER_NAME}"
fi
step_ok
