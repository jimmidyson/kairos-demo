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

next_out="$(next_step 2 2>&1)" || fail "next_step failed: ${next_out}"
[[ "${next_out}" == *"02-build-bases.sh"* ]] || fail "next_step path: ${next_out}"
[[ "${next_out}" != *"compgen"* ]] || fail "next_step used compgen: ${next_out}"

# %s must print real ESC, not the two-char sequence \033
_c_blue=$'\033[34;1m'
_c_reset=$'\033[0m'
colored="$(printf '%s▶%s' "${_c_blue}" "${_c_reset}")"
[[ "${colored}" == $'\033[34;1m▶\033[0m' ]] || fail "color codes not ESC"

echo "ok lib_test"
