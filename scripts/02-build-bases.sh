#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 2 "Build FIPS Kairos bases (3 OS × 2 arch)" \
  "kairos-init + FIPS + CIS L1 + STIG (if the tool has the profile). No kubeadm in the disk." \
  "$(image_prefix)/base:<os>-<arch>"

require_env UBUNTU_PRO_TOKEN
require_env OCI_REGISTRY
require_env OCI_REPOSITORY_PREFIX

VERSION="${KAIROS_IMAGE_VERSION}"
case "${VERSION}" in
  v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) ;;
  *)
    echo "KAIROS_IMAGE_VERSION=${VERSION} is not semver (kairos-init rejects git SHAs)" >&2
    exit 2
    ;;
esac

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
