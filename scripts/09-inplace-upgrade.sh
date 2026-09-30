#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 9 "In-place upgrade ${KUBERNETES_VERSION_OLD} → ${KUBERNETES_VERSION_NEW}" \
  "Patch the version. The Runtime Extension SSHes prepare-kubernetes-node and kubeadm. Machine names must stay." \
  "KubeadmControlPlane + MachineDeployment version"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
PREFIX="$(image_prefix)"
VER="${KUBERNETES_VERSION_NEW}"

before="$(kubectl get machines -l cluster.x-k8s.io/cluster-name=kairos-capi -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
printf '  machines before:\n%s\n' "${before}"

cluster_name="kairos-capi"
# Patch only the topology version. CAREN's kubernetesImageRepository is an
# immutable clusterConfig value, and preKubeadmCommand is no longer a topology
# variable because CAREN mutates the bootstrap templates itself.
kubectl patch cluster "${cluster_name}" --type=merge -p "{\"spec\":{\"topology\":{\"version\":\"${VER}\"}}}"

kcp="$(kubectl get kubeadmcontrolplane -l cluster.x-k8s.io/cluster-name=${cluster_name} -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${kcp}" ]] || kcp="${cluster_name}-control-plane"

kubectl wait --for=jsonpath='{.status.version}'="${VER}" "kubeadmcontrolplane/${kcp}" --timeout=45m
kubectl wait --for=condition=Ready "kubeadmcontrolplane/${kcp}" --timeout=45m

md="$(kubectl get machinedeployment -l cluster.x-k8s.io/cluster-name=${cluster_name} -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${md}" ]] || md="${cluster_name}-md-0"
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
