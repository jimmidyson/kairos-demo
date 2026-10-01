#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 8 "Create CAPX cluster at ${KUBERNETES_VERSION_OLD}" \
  "1 CP + 1 worker. CAREN deploys Cilium and Nutanix CCM after the control plane is up. maxSurge 0 so in-place can run." \
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

# Install or replace the factory node preparation patch. Reapplying the
# CAREN ClusterClass leaves a previously added patch in place, and skipping
# when the name exists would keep a stale command list.
prepare_patch_name="kairos-prepare-kubernetes-node"
prepare_patch_index="$(kubectl get clusterclass nutanix-quick-start -o json | jq -r --arg name "${prepare_patch_name}" '
  [(.spec.patches // []) | to_entries[] | select(.value.name == $name) | .key] | first // ""
')"
if [[ -n "${prepare_patch_index}" ]]; then
  prepare_patch_op="replace"
  prepare_patch_path="/spec/patches/${prepare_patch_index}"
else
  prepare_patch_op="add"
  prepare_patch_path="/spec/patches/-"
fi
prepare_patch_json="$(jq -nc \
  --arg prefix "${PREFIX}" \
  --arg op "${prepare_patch_op}" \
  --arg path "${prepare_patch_path}" '
    def cmd($version):
      "prepare-kubernetes-node --registry \($prefix) --kubernetes-version \($version)";
    # Appended after the provider hostnamectl command, before kubeadm.
    # Kairos symlinks /etc/hosts at a path systemd-sysext then covers with a
    # read-only /usr overlay. Remove the symlink and write a regular file.
    def hosts:
      "rm -f /etc/hosts; hn=$(hostnamectl --static 2>/dev/null || hostname); printf \"%s\\n\" \"127.0.0.1 localhost\" \"127.0.1.1 $hn\" \"::1 localhost ip6-localhost ip6-loopback\" \"fe00::0 ip6-localnet\" \"ff00::0 ip6-mcastprefix\" \"ff02::1 ip6-allnodes\" \"ff02::2 ip6-allrouters\" > /etc/hosts";
    [{
      op: $op,
      path: $path,
      value: {
        name: "kairos-prepare-kubernetes-node",
        definitions: [
          {
            selector: {
              apiVersion: "controlplane.cluster.x-k8s.io/v1beta2",
              kind: "KubeadmControlPlaneTemplate",
              matchResources: {controlPlane: true}
            },
            jsonPatches: [
              {op: "add", path: "/spec/template/spec/kubeadmConfigSpec/preKubeadmCommands/-", value: hosts},
              {
                op: "add",
                path: "/spec/template/spec/kubeadmConfigSpec/preKubeadmCommands/-",
                value: null,
                valueFrom: {template: cmd("{{ .builtin.controlPlane.version }}")}
              }
            ]
          },
          {
            selector: {
              apiVersion: "bootstrap.cluster.x-k8s.io/v1beta2",
              kind: "KubeadmConfigTemplate",
              matchResources: {machineDeploymentClass: {names: ["*"]}}
            },
            jsonPatches: [
              {op: "add", path: "/spec/template/spec/preKubeadmCommands/-", value: hosts},
              {
                op: "add",
                path: "/spec/template/spec/preKubeadmCommands/-",
                value: null,
                valueFrom: {template: cmd("{{ .builtin.machineDeployment.version }}")}
              }
            ]
          }
        ]
      }
    }]
  ')"
kubectl patch clusterclass nutanix-quick-start --type=json -p "${prepare_patch_json}"

CLUSTER_NAME="kairos-capi"
export CLUSTER_NAME KUBERNETES_VERSION PREFIX
bash "${ROOT}/scripts/render_cluster.sh" | kubectl apply --server-side -f -

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

printf '  waiting for control plane %s Ready\n' "${kcp}"
kubectl wait --for=condition=Ready "kubeadmcontrolplane/${kcp}" --timeout=60m
clusterctl get kubeconfig kairos-capi >"${ROOT}/build/kairos-capi.kubeconfig"
kubectl --kubeconfig="${ROOT}/build/kairos-capi.kubeconfig" wait --for=condition=Ready node --all --timeout=60m

step_ok
next_step 9
