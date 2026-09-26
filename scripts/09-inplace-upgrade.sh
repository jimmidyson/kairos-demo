#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 9 "In-place upgrade ${KUBERNETES_VERSION_OLD} → ${KUBERNETES_VERSION_NEW}" \
  "Patch the version. The Runtime Extension SSHes prepare-capi-node and kubeadm. Machine names must stay." \
  "KubeadmControlPlane + MachineDeployment version"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
PREFIX="$(image_prefix)"
VER="${KUBERNETES_VERSION_NEW}"

before="$(kubectl get machines -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
printf '  machines before:\n%s\n' "${before}"

kcp="$(kubectl get kubeadmcontrolplane -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${kcp}" ]] || kcp="kairos-capi-control-plane"
kcp_api="$(kubectl get kubeadmcontrolplane "${kcp}" -o jsonpath='{.apiVersion}')"
kubectl patch kubeadmcontrolplane "${kcp}" --type=merge \
  -p "$(python3 "${ROOT}/scripts/capi_patch.py" kcp --api-version "${kcp_api}" --version "${VER}" --prefix "${PREFIX}")"

kubectl wait --for=jsonpath='{.status.version}'="${VER}" "kubeadmcontrolplane/${kcp}" --timeout=45m
kubectl wait --for=condition=Ready "kubeadmcontrolplane/${kcp}" --timeout=45m

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

kubectl wait --for=condition=Available "machinedeployment/${md}" --timeout=45m
kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=45m

after="$(kubectl get machines -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
printf '  machines after:\n%s\n' "${after}"
while IFS= read -r n; do
  [[ -n "${n}" ]] || continue
  grep -F -qx "${n}" <<<"${after}" || { step_fail "machine ${n} was replaced — in-place failed"; exit 1; }
done <<<"${before}"

step_ok
next_step 10
