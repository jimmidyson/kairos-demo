#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 8 "Create CAPX cluster at ${KUBERNETES_VERSION_OLD}" \
  "1 CP + 1 worker, CABPK + prepare-capi-node, Cilium and CCM via CAAPH." \
  "Cluster kairos-capi in default namespace"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME="${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64}"
export CONTROL_PLANE_ENDPOINT_IP KUBERNETES_VERSION="${KUBERNETES_VERSION_OLD}"
PREFIX="$(image_prefix)"

mkdir -p "${ROOT}/build"
clusterctl generate cluster kairos-capi \
  --infrastructure nutanix \
  --kubernetes-version "${KUBERNETES_VERSION_OLD}" \
  --control-plane-machine-count=1 \
  --worker-machine-count=1 \
  >"${ROOT}/build/cluster.generated.yaml"

python3 - "${ROOT}/build/cluster.generated.yaml" "${PREFIX}" "${KUBERNETES_VERSION_OLD}" <<'PY'
import sys, re
path, prefix, ver = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
cmd = f"prepare-capi-node --registry {prefix} --kubernetes-version {ver}"
# Inject imageRepository + preKubeadmCommands into kubeadmConfigSpec blocks.
inject = (
    f"        imageRepository: {prefix}\n"
    f"        preKubeadmCommands:\n"
    f"        - {cmd}\n"
)
if "imageRepository:" not in text:
    text = text.replace("      kubeadmConfigSpec:\n", "      kubeadmConfigSpec:\n" + inject)
open(path, "w").write(text)
print(f"patched imageRepository={prefix} preKubeadmCommands={cmd}")
PY

kubectl apply -f "${ROOT}/build/cluster.generated.yaml"
kubectl apply -f "${ROOT}/capi/cilium.yaml"

printf '  waiting for control plane Ready (this talks to Prism; can take a long time)\n'
kubectl wait --for=condition=Ready kubeadmcontrolplane/kairos-capi-control-plane --timeout=60m
kubectl wait --for=condition=Ready node --all --timeout=60m --kubeconfig=/dev/null 2>/dev/null || true
# Workload kubeconfig
clusterctl get kubeconfig kairos-capi >"${ROOT}/build/kairos-capi.kubeconfig"
kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=60m

step_ok
next_step 9
