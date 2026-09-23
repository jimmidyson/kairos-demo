#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 4 "Build FIPS kubeadm images" \
  "apiserver/controller/scheduler/proxy/etcd/coredns with GOFIPS140=certified; pause retagged." \
  "$(image_prefix)/{kube-apiserver,kube-controller-manager,kube-scheduler,kube-proxy,etcd,coredns,pause}"

require_env OCI_REGISTRY
require_env OCI_REPOSITORY_PREFIX
chmod +x "${ROOT}/k8s-images/build.sh"
for ver in "${KUBERNETES_VERSION_OLD}" "${KUBERNETES_VERSION_NEW}"; do
  for arch in ${ARCHES}; do
    "${ROOT}/k8s-images/build.sh" "${ver}" "${arch}"
  done
done
step_ok
next_step 5
