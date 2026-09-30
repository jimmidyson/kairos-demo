#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=kubeadm-images.sh
source "${ROOT}/scripts/kubeadm-images.sh"

step_start 3 "Build containerd + kubernetes sysexts" \
  "containerd is per OS×arch (dynamically linked, built on the distro glibc). kubernetes is per version×arch." \
  "$(image_prefix)/containerd:… and $(image_prefix)/kubernetes:…"

require_env OCI_REGISTRY
require_env OCI_REPOSITORY_PREFIX
mkdir -p "${ROOT}/build/sysexts"

sysext_contexts=()
cleanup_sysext_contexts() {
  if ((${#sysext_contexts[@]} > 0)); then
    rm -rf -- "${sysext_contexts[@]}"
  fi
}
trap cleanup_sysext_contexts EXIT

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
  # AuroraBoot writes <name>.sysext.raw into --output. Remove a previous
  # artifact so rerunning step 3 remains safe: systemd-repart refuses to
  # overwrite an existing output image.
  local raw="${out}/${name}.sysext.raw"
  rm -f "${raw}"
  run_auroraboot_sysext "${name}" "${src_image}" "${arch}" "${out}"
  local ctx
  ctx="$(mktemp -d "${out}/${name}-oci.XXXXXX")"
  sysext_contexts+=("${ctx}")
  cp "${raw}" "${ctx}/${name}.sysext.raw"
  printf 'FROM scratch\nCOPY %s /%s\n' \
    "${name}.sysext.raw" "${name}.sysext.raw" >"${ctx}/Dockerfile"
  oci_build --platform="linux/${arch}" --push --tag="${dest_image}" "${ctx}"
}

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    src="$(image_prefix)/containerd-rootfs:${CONTAINERD_VERSION}-${os}-${arch}"
    printf '  containerd rootfs %s\n' "${src}"
    build_rootfs "${src}" --platform="linux/${arch}" \
      --file="${ROOT}/sysexts/Dockerfile.containerd" \
      --build-arg="BASE_IMAGE=$(distro_image "${os}")" \
      --build-arg="GO_VERSION=${GO_VERSION}" \
      --build-arg="LIBPATHRS_VERSION=${LIBPATHRS_VERSION}" \
      --build-arg="CONTAINERD_VERSION=${CONTAINERD_VERSION}" \
      --build-arg="RUNC_VERSION=${RUNC_VERSION}" \
      --build-arg="CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION}" \
      "${ROOT}"
    pack_sysext "${src}" "$(containerd_image "${os}" "${arch}" "${CONTAINERD_VERSION}")" \
      "containerd" "${arch}"
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
    pack_sysext "${src}" "$(kubernetes_image "${ver}" "${arch}")" "kubernetes" "${arch}"
  done
done

step_ok
next_step 4
