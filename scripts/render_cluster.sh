#!/usr/bin/env bash
# Render the CAPX Cluster. CAREN deploys Cilium and Nutanix CCM from clusterConfig.addons.
# Prism TLS follows NUTANIX_INSECURE / NUTANIX_CA_FILE. A CA file wins and forces insecure false,
# matching the old CCM Helm values. additionalTrustBundle is the base64 PEM CAREN expects.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

prism_insecure=false
prism_trust_line=""
if [[ -n "${NUTANIX_CA_FILE:-}" ]]; then
  b64="$(base64 <"${NUTANIX_CA_FILE}" | tr -d '\n')"
  prism_trust_line=$'\n            additionalTrustBundle: "'"${b64}"'"'
elif [[ "${NUTANIX_INSECURE:-}" == "1" ]]; then
  prism_insecure=true
fi
export PRISM_INSECURE="${prism_insecure}" PRISM_TRUST_LINE="${prism_trust_line}"

for v in CLUSTER_NAME KUBERNETES_VERSION PREFIX \
  NUTANIX_SSH_AUTHORIZED_KEY CONTROL_PLANE_ENDPOINT_IP NUTANIX_ENDPOINT \
  NUTANIX_PRISM_ELEMENT_CLUSTER_NAME NUTANIX_SUBNET_NAME PRISM_INSECURE; do
  if [[ -z "${!v:-}" ]]; then
    printf 'missing env: %s\n' "${v}" >&2
    exit 2
  fi
done

envsubst '${CLUSTER_NAME} ${KUBERNETES_VERSION} ${PREFIX} ${NUTANIX_SSH_AUTHORIZED_KEY} ${CONTROL_PLANE_ENDPOINT_IP} ${NUTANIX_ENDPOINT} ${NUTANIX_PRISM_ELEMENT_CLUSTER_NAME} ${NUTANIX_SUBNET_NAME} ${PRISM_INSECURE} ${PRISM_TRUST_LINE}' \
  <"${ROOT}/capi/cluster.yaml.tpl"
