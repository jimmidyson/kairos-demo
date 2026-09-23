#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
want='kube-apiserver kube-controller-manager kube-scheduler kube-proxy etcd coredns pause'
for n in ${want}; do
  grep -q "${n}" "${ROOT}/k8s-images/build.sh" || fail "k8s-images/build.sh missing ${n}"
done
echo "ok k8s_images_list_test"
