#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 3 "Build cri + kubernetes sysexts" \
  "cri is per OS×arch (dynamic containerd). kubernetes is per version×arch." \
  "$(image_prefix)/cri:… and $(image_prefix)/kubernetes:…"

require_env OCI_REGISTRY
require_env OCI_REPOSITORY_PREFIX
mkdir -p "${ROOT}/build/sysexts"

pack_sysext() {
  local src_image="$1" dest_image="$2" name="$3"
  local raw="${ROOT}/build/sysexts/${name}.raw"
  docker run --rm \
    -v "${ROOT}/build/sysexts:/build" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "${AURORABOOT_IMAGE}" \
    sysext --output="/build/${name}.raw" "${name}" "${src_image}"
  local ctx="${ROOT}/build/sysexts/${name}-oci"
  rm -rf "${ctx}"
  mkdir -p "${ctx}"
  cp "${raw}" "${ctx}/extension.raw"
  printf 'FROM scratch\nCOPY extension.raw /extension.raw\n' >"${ctx}/Dockerfile"
  docker buildx build --push --tag="${dest_image}" "${ctx}"
}

for os in ${OSES}; do
  for arch in ${ARCHES}; do
    src="$(image_prefix)/cri-rootfs:${os}-${arch}"
    printf '  cri rootfs %s\n' "${src}"
    docker buildx build --platform="linux/${arch}" --push \
      --file="${ROOT}/sysexts/Dockerfile.cri" \
      --build-arg="BASE_IMAGE=$(base_image "${os}" "${arch}")" \
      --build-arg="CONTAINERD_VERSION=${CONTAINERD_VERSION}" \
      --build-arg="RUNC_VERSION=${RUNC_VERSION}" \
      --build-arg="CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION}" \
      --tag="${src}" \
      "${ROOT}"
    pack_sysext "${src}" "$(cri_image "${os}" "${arch}")" "cri-${os}-${arch}"
  done
done

for ver in "${KUBERNETES_VERSION_OLD}" "${KUBERNETES_VERSION_NEW}"; do
  for arch in ${ARCHES}; do
    src="$(image_prefix)/kubernetes-rootfs:${ver}-${arch}"
    printf '  kubernetes rootfs %s\n' "${src}"
    docker buildx build --platform="linux/${arch}" --push \
      --file="${ROOT}/sysexts/Dockerfile.kubernetes" \
      --build-arg="K8S_VERSION=${ver}" \
      --tag="${src}" \
      "${ROOT}"
    pack_sysext "${src}" "$(kubernetes_image "${ver}" "${arch}")" "kubernetes-${ver}-${arch}"
  done
done

step_ok
next_step 4
