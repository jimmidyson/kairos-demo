#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=kubeadm-images.sh
source "${ROOT}/scripts/kubeadm-images.sh"

step_start 3 "Build cri + kubernetes sysexts" \
  "cri is per OS×arch (dynamic containerd, built on the distro glibc). kubernetes is per version×arch." \
  "$(image_prefix)/cri:… and $(image_prefix)/kubernetes:…"

require_env OCI_REGISTRY
require_env OCI_REPOSITORY_PREFIX
mkdir -p "${ROOT}/build/sysexts"

pause_tag_for() {
  local ver="$1" list tag
  list="$(kubeadm_image_list "${ver}" "$(image_prefix)")"
  tag="$(printf '%s\n' "${list}" | parse_image_list "$(image_prefix)" | pause_tag_from_list)"
  printf '%s\n' "${tag}"
}

build_rootfs() {
  local tag="$1"
  shift
  if registry_image_exists "${tag}"; then
    printf '  %s already in the registry; not rebuilding\n' "${tag}"
    return 0
  fi
  oci_build --push --tag="${tag}" "$@"
}

pack_sysext() {
  local src_image="$1" dest_image="$2" name="$3" arch="$4"
  local out="${ROOT}/build/sysexts"
  # AuroraBoot writes <name>.sysext.raw into --output.
  local raw="${out}/${name}.sysext.raw"
  run_auroraboot_sysext "${name}" "${src_image}" "${arch}" "${out}"
  local ctx="${ROOT}/build/sysexts/${name}-oci"
  rm -rf "${ctx}"
  mkdir -p "${ctx}"
  cp "${raw}" "${ctx}/extension.raw"
  printf 'FROM scratch\nCOPY extension.raw /extension.raw\n' >"${ctx}/Dockerfile"
  oci_build --platform="linux/${arch}" --push --tag="${dest_image}" "${ctx}"
}

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    src="$(image_prefix)/cri-rootfs:${os}-${arch}"
    printf '  cri rootfs %s\n' "${src}"
    build_rootfs "${src}" --platform="linux/${arch}" \
      --file="${ROOT}/sysexts/Dockerfile.cri" \
      --build-arg="BASE_IMAGE=$(distro_image "${os}")" \
      --build-arg="GO_VERSION=${GO_VERSION}" \
      --build-arg="CONTAINERD_VERSION=${CONTAINERD_VERSION}" \
      --build-arg="RUNC_VERSION=${RUNC_VERSION}" \
      --build-arg="CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION}" \
      "${ROOT}"
    pack_sysext "${src}" "$(cri_image "${os}" "${arch}")" "cri-${os}-${arch}" "${arch}"
  done
done

for ver in "${KUBERNETES_VERSION_OLD}" "${KUBERNETES_VERSION_NEW}"; do
  pause="$(pause_tag_for "${ver}")"
  printf '%s\n' "${pause}" >"${ROOT}/build/pause-tag-${ver}"
  for arch in ${ARCHES}; do
    src="$(image_prefix)/kubernetes-rootfs:${ver}-${arch}"
    printf '  kubernetes rootfs %s (pause %s)\n' "${src}" "${pause}"
    build_rootfs "${src}" --platform="linux/${arch}" \
      --file="${ROOT}/sysexts/Dockerfile.kubernetes" \
      --build-arg="K8S_VERSION=${ver}" \
      --build-arg="GO_VERSION=${GO_VERSION}" \
      --build-arg="RELEASE_VERSION=${KUBE_RELEASE_VERSION}" \
      --build-arg="PAUSE_TAG=${pause}" \
      "${ROOT}"
    pack_sysext "${src}" "$(kubernetes_image "${ver}" "${arch}")" "kubernetes-${ver}-${arch}" "${arch}"
  done
done

step_ok
next_step 4
