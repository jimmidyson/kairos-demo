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
credential_json="$(jq -nc \
  --arg user "${NUTANIX_USER}" \
  --arg password "${NUTANIX_PASSWORD}" \
  '[{type:"basic_auth",data:{prismCentral:{username:$user,password:$password},prismElements:null}}]')"
# ${credential_json} is expanded once; a password containing $() stays literal.
kubectl apply --server-side -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nutanix-credentials
  namespace: default
stringData:
  credentials: |
    ${credential_json}
EOF

# CAREN supplies the CAPX ClusterClass and all referenced templates. Machine
# details, Prism endpoints, and credentials are supplied through clusterConfig
# and workerConfig below; do not apply local machine-template overrides here.
kubectl apply --server-side --force-conflicts -f "https://github.com/nutanix-cloud-native/cluster-api-runtime-extensions-nutanix/releases/download/${CAREN_VERSION}/nutanix-cluster-class.yaml"

# Add the factory node preparation as a ClusterClass inline patch. The
# topology version is resolved by CAPI for each generated template, so this
# remains correct during in-place upgrades as well as initial provisioning.
prepare_patch_name="kairos-prepare-kubernetes-node"
if ! kubectl get clusterclass nutanix-quick-start -o jsonpath='{.spec.patches[*].name}' | grep -qw "${prepare_patch_name}"; then
  prepare_patch_json="$(jq -nc --arg prefix "${PREFIX}" '
    def cmd($version):
      "prepare-kubernetes-node --registry \($prefix) --kubernetes-version \($version)";
    [{
      op: "add",
      path: "/spec/patches/-",
      value: {
        name: "kairos-prepare-kubernetes-node",
        definitions: [
          {
            selector: {
              apiVersion: "controlplane.cluster.x-k8s.io/v1beta2",
              kind: "KubeadmControlPlaneTemplate",
              matchResources: {controlPlane: true}
            },
            jsonPatches: [{
              op: "add",
              path: "/spec/template/spec/kubeadmConfigSpec/preKubeadmCommands/-",
              value: null,
              valueFrom: {template: cmd("{{ .builtin.controlPlane.version }}")}
            }]
          },
          {
            selector: {
              apiVersion: "bootstrap.cluster.x-k8s.io/v1beta2",
              kind: "KubeadmConfigTemplate",
              matchResources: {machineDeploymentClass: {names: ["*"]}}
            },
            jsonPatches: [{
              op: "add",
              path: "/spec/template/spec/preKubeadmCommands/-",
              value: null,
              valueFrom: {template: cmd("{{ .builtin.machineDeployment.version }}")}
            }]
          }
        ]
      }
    }]
  ')"
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
bash "${ROOT}/scripts/render_ccm.sh" >"${ROOT}/build/ccm.yaml"
kubectl apply --server-side -f "${ROOT}/build/ccm.yaml"

printf '  waiting for control plane %s Ready\n' "${kcp}"
kubectl wait --for=condition=Ready "kubeadmcontrolplane/${kcp}" --timeout=60m
clusterctl get kubeconfig kairos-capi >"${ROOT}/build/kairos-capi.kubeconfig"
kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=60m

step_ok
next_step 9
