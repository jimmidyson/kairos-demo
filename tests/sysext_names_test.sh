#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export OCI_REGISTRY=h.example OCI_REPOSITORY_PREFIX=p
[[ "$(containerd_image ubuntu-22.04 amd64 2.4.0)" == "h.example/p/containerd:2.4.0-ubuntu-22.04-amd64" ]] || fail containerd
[[ "$(kubernetes_image v1.35.8 arm64)" == "h.example/p/kubernetes:v1.35.8-arm64" ]] || fail k8s

grep -q 'containerd-.*CONTAINERD_VERSION.*-.*-.*' "${ROOT}/scripts/03-build-sysexts.sh" || fail "versioned containerd name"
grep -q 'kubernetes-.*-.*' "${ROOT}/scripts/03-build-sysexts.sh" || fail "versioned kubernetes name"
grep -q 'GOFIPS140=certified' "${ROOT}/sysexts/Dockerfile.cri" || fail "cri FIPS"
grep -q 'pause-tag' "${ROOT}/sysexts/Dockerfile.kubernetes" || fail "pause tag file"
echo "ok sysext_names_test"
