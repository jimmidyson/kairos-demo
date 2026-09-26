#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 5 "Management cluster + kairos-operator + OSArtifact cloud disks" \
  "Build preinstalled VM disks. Download only Ubuntu 24.04 amd64 for CAPX." \
  "cluster ${KAIROS_KIND_CLUSTER_NAME} ($(mgmt_name)), OSArtifacts cloud-<os>-<arch>"

require_env OCI_REGISTRY
require_env OCI_REGISTRY_USERNAME
require_env OCI_REGISTRY_PASSWORD
require_env NUTANIX_SSH_AUTHORIZED_KEY
export KUBECONFIG="${ROOT}/kairos-kind.kubeconfig"

if mgmt_exists "${KAIROS_KIND_CLUSTER_NAME}"; then
  printf '  management cluster %s already exists\n' "${KAIROS_KIND_CLUSTER_NAME}"
else
  mgmt_create "${KAIROS_KIND_CLUSTER_NAME}"
fi
mgmt_write_kubeconfig "${KAIROS_KIND_CLUSTER_NAME}" "${KUBECONFIG}"

kubectl create secret docker-registry oci-registry-secret \
  --dry-run=client -o yaml \
  --docker-server="${OCI_REGISTRY}" \
  --docker-username="${OCI_REGISTRY_USERNAME}" \
  --docker-password="${OCI_REGISTRY_PASSWORD}" \
  | kubectl apply --server-side -f -

op_ref="${KAIROS_OPERATOR_REF}"
kubectl apply -k "https://github.com/kairos-io/kairos-operator/config/default?ref=${op_ref}"
# That kustomize pins the previous release image (v0.2.2's file says v0.2.1).
kubectl -n operator-system set image deploy/operator-kairos-operator \
  manager="quay.io/kairos/operator:${op_ref}"
kubectl -n operator-system set env deploy/operator-kairos-operator \
  OPERATOR_IMAGE="quay.io/kairos/operator:${op_ref}" \
  NODE_LABELER_IMAGE="quay.io/kairos/operator-node-labeler:${op_ref}"
kubectl apply -k "https://github.com/kairos-io/kairos-operator/config/nginx?ref=${op_ref}"
kubectl wait --for=condition=Established crd/osartifacts.build.kairos.io --timeout=180s
# config/default sets namespace operator-system and namePrefix operator-.
# config/nginx is unprefixed; the Deployment is named nginx, the Service kairos-operator-nginx.
kubectl -n operator-system rollout status deploy/operator-kairos-operator --timeout=180s
kubectl -n default rollout status deploy/nginx --timeout=180s

rendered_cloud="$(envsubst '${NUTANIX_SSH_AUTHORIZED_KEY}' <"${ROOT}/image/cloud-config.yaml")"

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    printf '  OSArtifact cloud-%s-%s\n' "${os}" "${arch}"
    # OSArtifact reconciliation is not an imperative rebuild: an unchanged
    # Ready resource reuses its completed build. Delete it first so rerunning
    # step 5 always creates a fresh disk and exporter job.
    kubectl delete "osartifact/cloud-${os}-${arch}" --ignore-not-found --wait=true
    OS="${os}" ARCH="${arch}" BASE_IMAGE="$(base_image "${os}" "${arch}")" \
      CLOUD_CONFIG="$(printf '%s\n' "${rendered_cloud}" | sed 's/^/    /')" \
      envsubst '${OS} ${ARCH} ${BASE_IMAGE} ${CLOUD_CONFIG}' <"${ROOT}/osartifact/cloud-image.yaml.tpl" \
      | kubectl apply --server-side -f -
  done
done

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    kubectl wait --for=jsonpath='{.status.phase}'=Ready "osartifacts/cloud-${os}-${arch}" --timeout=60m
  done
done

mkdir -p "${ROOT}/build"
dest="${ROOT}/build/ubuntu-24.04-amd64.raw"
pf_log="${ROOT}/build/nginx-port-forward.log"
kubectl -n default port-forward svc/kairos-operator-nginx 18080:80 >"${pf_log}" 2>&1 &
pf_pid=$!
cleanup_pf() { kill "${pf_pid}" 2>/dev/null || true; }
trap cleanup_pf EXIT
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl -fsS "http://127.0.0.1:18080/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
  step_fail "kairos-operator-nginx port-forward did not come up; see ${pf_log}"
  exit 1
fi
if ! curl -fL "http://127.0.0.1:18080/cloud-ubuntu-24.04-amd64.raw" -o "${dest}"; then
  step_fail "cloud-ubuntu-24.04-amd64.raw was not on the operator nginx"
  exit 1
fi
if [[ ! -s "${dest}" ]]; then
  step_fail "downloaded disk is empty"
  exit 1
fi

step_ok
next_step 6
