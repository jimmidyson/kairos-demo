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
[[ "$(etcd_git_ref 3.6.8-0)" == "v3.6.8" ]] || fail "etcd image revision: $(etcd_git_ref 3.6.8-0)"
[[ "$(etcd_git_ref 3.5.21-0)" == "v3.5.21" ]] || fail "etcd image revision: $(etcd_git_ref 3.5.21-0)"
[[ "$(etcd_git_ref v3.6.8)" == "v3.6.8" ]] || fail "etcd tag already versioned: $(etcd_git_ref v3.6.8)"

grep -q 'kubeadm_image_list' "${ROOT}/k8s-images/build.sh" || fail "build.sh must ask kubeadm for the image list"
grep -q 'crane index append' "${ROOT}/k8s-images/build.sh" || fail "build.sh must publish a manifest list with crane"
grep -q 'crane copy' "${ROOT}/k8s-images/build.sh" || fail "pause is a retag"
grep -q 'GOTMPDIR=' "${ROOT}/k8s-images/build.sh" || fail "go compile temps must not use the small /tmp"
grep -q '_output/local/bin/linux/' "${ROOT}/k8s-images/build.sh" || fail "kube binaries come from the platform output dir"
grep -q 'build_k8s_bins "${arch}" kube-apiserver kube-controller-manager kube-scheduler kube-proxy' "${ROOT}/k8s-images/build.sh" || fail "one make builds every kubeadm Kubernetes binary"
grep -q 'WORKDIR}/bin/etcd-${arch}' "${ROOT}/k8s-images/build.sh" || fail "etcd binary must not be the image context path"
grep -q 'WORKDIR}/bin/coredns-${arch}' "${ROOT}/k8s-images/build.sh" || fail "coredns binary must not be the image context path"
grep -q 'rm -rf "${ctx}"' "${ROOT}/k8s-images/build.sh" || fail "image context must replace a leftover file"

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
