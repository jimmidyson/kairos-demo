#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export OCI_REGISTRY=h.example OCI_REPOSITORY_PREFIX=p
[[ "$(cri_image ubuntu-22.04 amd64)" == "h.example/p/cri:ubuntu-22.04-amd64" ]] || fail cri
[[ "$(kubernetes_image v1.35.8 arm64)" == "h.example/p/kubernetes:v1.35.8-arm64" ]] || fail k8s
echo "ok sysext_names_test"
