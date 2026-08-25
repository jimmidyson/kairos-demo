#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 9 "In-place upgrade ${KUBERNETES_VERSION_OLD} → ${KUBERNETES_VERSION_NEW}" \
  "Same Machines. prepare-capi-node swaps the kubernetes sysext; kubeadm upgrade follows." \
  "KubeadmControlPlane + MachineDeployment version"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
PREFIX="$(image_prefix)"
SSH_KEY="${SSH_IDENTITY_FILE:-${HOME}/.ssh/id_ed25519}"

before="$(kubectl get machines -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.version}{"\n"}{end}')"
printf '  machines before:\n%s\n' "${before}"

mapfile -t NAMES < <(kubectl get machines -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

kubectl patch kubeadmcontrolplane kairos-capi-control-plane --type merge -p "{\"spec\":{\"version\":\"${KUBERNETES_VERSION_NEW}\",\"kubeadmConfigSpec\":{\"clusterConfiguration\":{\"imageRepository\":\"${PREFIX}\"}}}}"
kubectl patch machinedeployment kairos-capi-md-0 --type merge -p "{\"spec\":{\"template\":{\"spec\":{\"version\":\"${KUBERNETES_VERSION_NEW}\"}}}}" \
  || kubectl get machinedeployment -o name | head -1 | xargs -I{} kubectl patch {} --type merge -p "{\"spec\":{\"template\":{\"spec\":{\"version\":\"${KUBERNETES_VERSION_NEW}\"}}}}"

while IFS=$'\t' read -r name ver; do
  [[ -n "${name}" ]] || continue
  img="$(kubectl get machine "${name}" -o jsonpath='{.spec.infrastructureRef.name}')"
  if ! "${ROOT}/build/inplace-extension" can-update "${img}" "${img}" "${ver}" "${KUBERNETES_VERSION_NEW}"; then
    step_fail "CanUpdateInPlace false for ${name} (image would change — CAPI would roll a new VM)"
    exit 1
  fi
  addr="$(kubectl get machine "${name}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  role=worker
  kubectl get machine "${name}" -o jsonpath='{.metadata.labels}' | grep -q control-plane && role=cp
  printf '  update %s (%s) %s → %s via %s\n' "${name}" "${role}" "${ver}" "${KUBERNETES_VERSION_NEW}" "${addr}"
  "${ROOT}/build/inplace-extension" update-machine nkpadmin "${addr}" "${SSH_KEY}" "${PREFIX}" "${KUBERNETES_VERSION_NEW}" "${role}"
done <<<"${before}"

kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=45m

after="$(kubectl get machines -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
printf '  machines after:\n%s\n' "${after}"
for n in "${NAMES[@]}"; do
  grep -qx "${n}" <<<"${after}" || { step_fail "machine ${n} was replaced — in-place failed"; exit 1; }
done

step_ok
next_step 10
