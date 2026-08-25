#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

out="$(require_env NOT_A_REAL_ENV 2>&1)" && fail "require_env should fail" || true
[[ "${out}" == *"missing env: NOT_A_REAL_ENV"* ]] || fail "got: ${out}"

export OCI_REGISTRY=harbor.example.com
export OCI_REPOSITORY_PREFIX=kairos-demo
[[ "$(image_prefix)" == "harbor.example.com/kairos-demo" ]] || fail "image_prefix"

[[ "$(base_image ubuntu-24.04 amd64)" == "harbor.example.com/kairos-demo/base:ubuntu-24.04-amd64" ]] || fail "base_image"
[[ "$(cri_image rocky-9 arm64)" == "harbor.example.com/kairos-demo/cri:rocky-9-arm64" ]] || fail "cri_image"
[[ "$(kubernetes_image v1.36.4 amd64)" == "harbor.example.com/kairos-demo/kubernetes:v1.36.4-amd64" ]] || fail "kubernetes_image"

echo "ok lib_test"
