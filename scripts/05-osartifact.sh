#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 5 "KIND + kairos-operator + OSArtifact cloud disks" \
  "Build preinstalled VM disks. Download only Ubuntu 24.04 amd64 for CAPX." \
  "KIND ${KAIROS_KIND_CLUSTER_NAME}, OSArtifacts cloud-<os>-<arch>"

require_env OCI_REGISTRY
require_env OCI_REGISTRY_USERNAME
require_env OCI_REGISTRY_PASSWORD
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"

if kind get clusters 2>/dev/null | grep -qx "${KAIROS_KIND_CLUSTER_NAME}"; then
  printf '  KIND cluster %s already exists\n' "${KAIROS_KIND_CLUSTER_NAME}"
else
  kind create cluster --name "${KAIROS_KIND_CLUSTER_NAME}"
fi
kind get kubeconfig --name "${KAIROS_KIND_CLUSTER_NAME}" >"${KUBECONFIG}"

kubectl create secret docker-registry oci-registry-secret \
  --dry-run=client -o yaml \
  --docker-server="${OCI_REGISTRY}" \
  --docker-username="${OCI_REGISTRY_USERNAME}" \
  --docker-password="${OCI_REGISTRY_PASSWORD}" \
  | kubectl apply --server-side -f -

kubectl apply -k https://github.com/kairos-io/kairos-operator/config/default
kubectl wait --for=condition=Established crd/osartifacts.build.kairos.io --timeout=180s

rendered_cloud="$(envsubst <"${ROOT}/image/cloud-config.yaml")"

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    printf '  OSArtifact cloud-%s-%s\n' "${os}" "${arch}"
    OS="${os}" ARCH="${arch}" BASE_IMAGE="$(base_image "${os}" "${arch}")" \
    CLOUD_CONFIG="$(printf '%s\n' "${rendered_cloud}" | sed 's/^/    /')" \
    envsubst <"${ROOT}/osartifact/cloud-image.yaml.tpl" | kubectl apply --server-side -f -
  done
done

kubectl wait --for=jsonpath='{.status.phase}'=Ready "osartifacts/cloud-ubuntu-24.04-amd64" --timeout=60m

mkdir -p "${ROOT}/build"
# ponytail: fetch via operator nginx NodePort if present
if kubectl get svc kairos-operator-nginx >/dev/null 2>&1; then
  port="$(kubectl get svc kairos-operator-nginx -o jsonpath='{.spec.ports[0].nodePort}')"
  printf '  download ubuntu-24.04 amd64 disk from nginx nodePort %s\n' "${port}"
  curl -fL "http://127.0.0.1:${port}/cloud-ubuntu-24.04-amd64.raw" -o "${ROOT}/build/ubuntu-24.04-amd64.raw" \
    || printf '  could not download raw disk automatically; copy it from the OSArtifact exporter\n'
fi

step_ok
next_step 6
