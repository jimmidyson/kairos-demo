#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 2 "Build FIPS Kairos bases (3 OS × 2 arch)" \
  "OS FIPS + kairos-init + prepare-capi-node. No kubeadm in the disk." \
  "$(image_prefix)/base:<os>-<arch>"

require_env UBUNTU_PRO_TOKEN
require_env OCI_REGISTRY
require_env OCI_REPOSITORY_PREFIX

VERSION="${VERSION:-$(git -C "${ROOT}" describe --always --dirty 2>/dev/null || echo dev)}"

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    tag="$(base_image "${os}" "${arch}")"
    printf '  building %s\n' "${tag}"
    df="${ROOT}/image/Dockerfile.ubuntu"
    base_img="ubuntu:${os#ubuntu-}"
    if [[ "${os}" == rocky-9 ]]; then
      df="${ROOT}/image/Dockerfile.rocky"
      base_img="rockylinux:9"
    fi
    docker buildx build \
      --platform="linux/${arch}" \
      --push \
      --file="${df}" \
      --build-arg="BASE_IMAGE=${base_img}" \
      --build-arg="KAIROS_INIT_VERSION=${KAIROS_INIT_VERSION}" \
      --build-arg="VERSION=${VERSION}" \
      --secret="id=ubuntu-pro-token,env=UBUNTU_PRO_TOKEN" \
      --tag="${tag}" \
      "${ROOT}"
  done
done

step_ok
next_step 3
