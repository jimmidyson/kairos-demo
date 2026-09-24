#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=../scripts/kubeadm-images.sh
source "${ROOT}/scripts/kubeadm-images.sh"
# shellcheck source=../scripts/enable-fips-go.sh
source "${ROOT}/scripts/enable-fips-go.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

prefix="harbor.example/p"
list="$(cat <<EOF
${prefix}/kube-apiserver:v1.35.8
${prefix}/kube-controller-manager:v1.35.8
${prefix}/kube-scheduler:v1.35.8
${prefix}/kube-proxy:v1.35.8
${prefix}/etcd:3.6.5
${prefix}/coredns/coredns:v1.12.1
${prefix}/pause:3.10.1
EOF
)"

parsed="$(printf '%s\n' "${list}" | parse_image_list "${prefix}")"
printf '%s\n' "${parsed}" | grep -q $'^etcd\t3.6.5$' || fail "etcd tag must be the etcd version, got: ${parsed}"
printf '%s\n' "${parsed}" | grep -q $'^coredns/coredns\tv1.12.1$' || fail "coredns path: ${parsed}"
tag="$(printf '%s\n' "${parsed}" | pause_tag_from_list)"
[[ "${tag}" == "3.10.1" ]] || fail "pause tag ${tag}"

grep -q 'kubeadm_image_list' "${ROOT}/k8s-images/build.sh" || fail "build.sh must ask kubeadm for the image list"
grep -q 'crane index append' "${ROOT}/k8s-images/build.sh" || fail "build.sh must publish a manifest list with crane"
grep -q 'crane copy' "${ROOT}/k8s-images/build.sh" || fail "pause is a retag"

enable_fips_go 1.25.4
[[ "${GOFIPS140}" == "certified" ]] || fail "GOFIPS140"
[[ "${GOTOOLCHAIN}" == "go1.25.10" ]] || fail "1.25.4 toolchain ${GOTOOLCHAIN:-unset}"
enable_fips_go 1.25.10
[[ -z "${GOTOOLCHAIN:-}" ]] || fail "1.25.10 should keep its own toolchain"
enable_fips_go 1.26.0
[[ "${GOTOOLCHAIN}" == "go1.26.3" ]] || fail "1.26.0 toolchain"
enable_fips_go 1.26.5
[[ -z "${GOTOOLCHAIN:-}" ]] || fail "1.26.5 should keep its own toolchain"

echo "ok k8s_images_list_test"
