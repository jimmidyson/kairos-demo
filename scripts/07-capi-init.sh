#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 7 "clusterctl init CAPX + CAAPH + CAREN + in-place Runtime Extension" \
  "The management cluster ($(mgmt_name)) runs CAPI. CAREN supplies the Nutanix ClusterClass and runtime hooks; the local extension handles in-place upgrades." \
  "namespaces capi-system, capx-system, caaph-system, caren-system, kairos-inplace-system"

require_factory_env
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"
export EXP_IN_PLACE_UPDATES=true CLUSTER_TOPOLOGY=true EXP_RUNTIME_SDK=true EXP_MACHINE_TAINT_PROPAGATION=true

if ! mgmt_exists "${KAIROS_KIND_CLUSTER_NAME}"; then
  step_fail "management cluster ${KAIROS_KIND_CLUSTER_NAME} is missing; run step 5"
  exit 1
fi
mgmt_write_kubeconfig "${KAIROS_KIND_CLUSTER_NAME}" "${KUBECONFIG}"

clusterctl init \
  --core "cluster-api:${CAPI_VERSION}" \
  --bootstrap "kubeadm:${CAPI_VERSION}" \
  --control-plane "kubeadm:${CAPI_VERSION}" \
  --infrastructure "nutanix:${CAPX_VERSION}" \
  --addon "helm:${CAAPH_VERSION}" \
  --runtime-extension "nutanix:${CAREN_VERSION}" \
  --wait-providers

ssh_key="${SSH_IDENTITY_FILE:-}"
if [[ -z "${ssh_key}" ]]; then
  if [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
    ssh_key="${HOME}/.ssh/id_ed25519"
  elif [[ -f "${HOME}/.ssh/id_rsa" ]]; then
    ssh_key="${HOME}/.ssh/id_rsa"
  else
    step_fail "set SSH_IDENTITY_FILE to the private key for NUTANIX_SSH_AUTHORIZED_KEY"
    exit 1
  fi
fi
if [[ ! -f "${ssh_key}" ]]; then
  step_fail "SSH_IDENTITY_FILE ${ssh_key} does not exist"
  exit 1
fi

command -v openssl >/dev/null || { step_fail "openssl is required to mint the extension serving cert"; exit 1; }

mgmt_build_and_load "${CAPI_EXTENSION_IMAGE}" "${ROOT}/extension/Dockerfile" "${ROOT}/extension" \
  --build-arg "GO_VERSION=${GO_VERSION}"

kubectl create namespace kairos-inplace-system --dry-run=client -o yaml | kubectl apply --server-side -f -
if ! kubectl -n kairos-inplace-system get secret inplace-tls >/dev/null 2>&1; then
  cert_dir="$(mktemp -d)"
  cat >"${cert_dir}/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = kairos-inplace.kairos-inplace-system.svc
[v3]
subjectAltName = DNS:kairos-inplace.kairos-inplace-system.svc,DNS:kairos-inplace.kairos-inplace-system.svc.cluster.local
EOF
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${cert_dir}/tls.key" -out "${cert_dir}/tls.crt" \
    -days 825 -nodes \
    -config "${cert_dir}/openssl.cnf"
  kubectl -n kairos-inplace-system create secret tls inplace-tls \
    --cert="${cert_dir}/tls.crt" --key="${cert_dir}/tls.key"
  rm -rf "${cert_dir}"
fi
kubectl -n kairos-inplace-system create secret generic inplace-ssh \
  --from-file=id="${ssh_key}" \
  --dry-run=client -o yaml | kubectl apply --server-side -f -

export IMAGE_PREFIX
IMAGE_PREFIX="$(image_prefix)"
export CAPI_EXTENSION_IMAGE
envsubst '${CAPI_EXTENSION_IMAGE} ${IMAGE_PREFIX}' <"${ROOT}/capi/inplace-extension.yaml" | kubectl apply --server-side -f -

ca_bundle="$(kubectl -n kairos-inplace-system get secret inplace-tls -o jsonpath='{.data.tls\.crt}')"
cat <<EOF | kubectl apply --server-side -f -
apiVersion: runtime.cluster.x-k8s.io/v1beta2
kind: ExtensionConfig
metadata:
  name: kairos-inplace
spec:
  clientConfig:
    caBundle: ${ca_bundle}
    service:
      name: kairos-inplace
      namespace: kairos-inplace-system
      port: 443
EOF

kubectl -n kairos-inplace-system rollout status deploy/kairos-inplace --timeout=180s
kubectl -n capi-system rollout status deploy/capi-controller-manager --timeout=180s

step_ok
next_step 8
