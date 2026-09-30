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
export CONTROL_PLANE_ENDPOINT_IP KUBERNETES_VERSION="${KUBERNETES_VERSION_OLD}"
PREFIX="$(image_prefix)"
VER="${KUBERNETES_VERSION_OLD}"

mkdir -p "${ROOT}/build"

# Create the CAPX credential secret expected by NutanixClusterTemplate.
# The credential controller reads the `credentials` key; username/password
# keys alone produce: no "credentials" data found in secret.
NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT}" NUTANIX_USER="${NUTANIX_USER}" \
  NUTANIX_PASSWORD="${NUTANIX_PASSWORD}" python3 - <<'PY' | kubectl apply --server-side -f -
import json
import os

credentials = [{
    "type": "basic_auth",
    "data": {
        "prismCentral": {
            "username": os.environ["NUTANIX_USER"],
            "password": os.environ["NUTANIX_PASSWORD"],
        },
        "prismElements": None,
    },
}]
credential_json = json.dumps(credentials, separators=(",", ":"))
print("""apiVersion: v1
kind: Secret
metadata:
  name: nutanix-credentials
  namespace: default
stringData:
  credentials: |
    %s
""" % credential_json)
PY

# CAREN supplies the CAPX ClusterClass and all referenced templates. Machine
# details, Prism endpoints, and credentials are supplied through clusterConfig
# and workerConfig below; do not apply local machine-template overrides here.
kubectl apply --server-side --force-conflicts -f "https://github.com/nutanix-cloud-native/cluster-api-runtime-extensions-nutanix/releases/download/${CAREN_VERSION}/nutanix-cluster-class.yaml"

# Add the factory node preparation as a ClusterClass inline patch. The
# topology version is resolved by CAPI for each generated template, so this
# remains correct during in-place upgrades as well as initial provisioning.
prepare_patch_name="kairos-prepare-kubernetes-node"
if ! kubectl get clusterclass nutanix-quick-start -o jsonpath='{.spec.patches[*].name}' | grep -qw "${prepare_patch_name}"; then
  prepare_patch_json="$(PREFIX="${PREFIX}" python3 - <<'PY'
import json
import os

prefix = os.environ["PREFIX"]
patch = {
    "op": "add",
    "path": "/spec/template/spec/kubeadmConfigSpec/preKubeadmCommands/-",
    "value": None,
}
worker_patch = {
    "op": "add",
    "path": "/spec/template/spec/preKubeadmCommands/-",
    "value": None,
}
control_plane_value_from = {
    "template": (
        "prepare-kubernetes-node --registry %s --kubernetes-version "
        "{{ .builtin.controlPlane.version }}"
    ) % prefix,
}
worker_value_from = {
    "template": (
        "prepare-kubernetes-node --registry %s --kubernetes-version "
        "{{ .builtin.machineDeployment.version }}"
    ) % prefix,
}
patch["valueFrom"] = control_plane_value_from
worker_patch["valueFrom"] = worker_value_from
print(json.dumps([{
    "op": "add",
    "path": "/spec/patches/-",
    "value": {
        "name": "kairos-prepare-kubernetes-node",
        "definitions": [
            {
                "selector": {
                    "apiVersion": "controlplane.cluster.x-k8s.io/v1beta2",
                    "kind": "KubeadmControlPlaneTemplate",
                    "matchResources": {"controlPlane": True},
                },
                "jsonPatches": [patch],
            },
            {
                "selector": {
                    "apiVersion": "bootstrap.cluster.x-k8s.io/v1beta2",
                    "kind": "KubeadmConfigTemplate",
                    "matchResources": {
                        "machineDeploymentClass": {"names": ["*"]},
                    },
                },
                "jsonPatches": [worker_patch],
            },
        ],
    },
}]))
PY
)"
  kubectl patch clusterclass nutanix-quick-start --type=json -p "${prepare_patch_json}"
fi

CLUSTER_NAME="kairos-capi"
export CLUSTER_NAME KUBERNETES_VERSION PREFIX
envsubst '${CLUSTER_NAME} ${KUBERNETES_VERSION} ${PREFIX}' <"${ROOT}/capi/cluster.yaml.tpl" | kubectl apply --server-side -f -

# Wait for control plane to be created via topology
kcp=""
printf '  waiting for kubeadmcontrolplane for cluster %s to be created\n' "${CLUSTER_NAME}"
until [[ -n "${kcp}" ]]; do
  kcp="$(kubectl get kubeadmcontrolplane \
    -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" \
    -o name 2>/dev/null | head -n1 | cut -d/ -f2 || true)"
  if [[ -z "${kcp}" ]]; then
    sleep 2
  fi
done

export CILIUM_CHART_VERSION
kubectl apply --server-side -f <(envsubst '${CILIUM_CHART_VERSION}' <"${ROOT}/capi/cilium.yaml")
python3 "${ROOT}/scripts/render_ccm.py" >"${ROOT}/build/ccm.yaml"
kubectl apply --server-side -f "${ROOT}/build/ccm.yaml"

printf '  waiting for control plane %s Ready\n' "${kcp}"
kubectl wait --for=condition=Ready "kubeadmcontrolplane/${kcp}" --timeout=60m
clusterctl get kubeconfig kairos-capi >"${ROOT}/build/kairos-capi.kubeconfig"
kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=60m

step_ok
next_step 9
