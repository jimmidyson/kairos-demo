#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 8 "Create CAPX cluster at ${KUBERNETES_VERSION_OLD}" \
  "1 CP + 1 worker. imageRepository is under clusterConfiguration. maxSurge 0 so in-place can run." \
  "Cluster kairos-capi in default namespace"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME="${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64}"
export CONTROL_PLANE_ENDPOINT_IP KUBERNETES_VERSION="${KUBERNETES_VERSION_OLD}"
PREFIX="$(image_prefix)"
VER="${KUBERNETES_VERSION_OLD}"

mkdir -p "${ROOT}/build"
clusterctl generate cluster kairos-capi \
  --infrastructure nutanix \
  --kubernetes-version "${VER}" \
  --control-plane-machine-count=1 \
  --worker-machine-count=1 \
  >"${ROOT}/build/cluster.generated.yaml"

kubectl apply -f "${ROOT}/build/cluster.generated.yaml"

kcp="$(kubectl get kubeadmcontrolplane -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${kcp}" ]] || kcp="kairos-capi-control-plane"
kcp_api="$(kubectl get kubeadmcontrolplane "${kcp}" -o jsonpath='{.apiVersion}')"
kubectl patch kubeadmcontrolplane "${kcp}" --type=merge \
  -p "$(python3 "${ROOT}/scripts/capi_patch.py" kcp --api-version "${kcp_api}" --version "${VER}" --prefix "${PREFIX}")"

md="$(kubectl get machinedeployment -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${md}" ]] || md="kairos-capi-md-0"
md_api="$(kubectl get machinedeployment "${md}" -o jsonpath='{.apiVersion}')"
kubectl patch machinedeployment "${md}" --type=merge \
  -p "$(python3 "${ROOT}/scripts/capi_patch.py" md --api-version "${md_api}" --version "${VER}")"

kcts="$(kubectl get kubeadmconfigtemplate -l cluster.x-k8s.io/cluster-name=kairos-capi -o name)"
if [[ -z "${kcts}" ]]; then
  kcts="$(kubectl get kubeadmconfigtemplate -o name)"
fi
while IFS= read -r kct; do
  [[ -n "${kct}" ]] || continue
  kubectl patch "${kct}" --type=merge \
    -p "$(python3 "${ROOT}/scripts/capi_patch.py" kct --prefix "${PREFIX}" --version "${VER}")"
done <<<"${kcts}"

kubectl apply -f "${ROOT}/capi/cilium.yaml"
python3 "${ROOT}/scripts/render_ccm.py" >"${ROOT}/build/ccm.yaml"
kubectl apply -f "${ROOT}/build/ccm.yaml"

printf '  waiting for control plane Ready\n'
kubectl wait --for=condition=Ready "kubeadmcontrolplane/${kcp}" --timeout=60m
clusterctl get kubeconfig kairos-capi >"${ROOT}/build/kairos-capi.kubeconfig"
kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=60m

step_ok
next_step 9
