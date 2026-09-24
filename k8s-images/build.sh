#!/usr/bin/env bash
# Build FIPS kubeadm images for one Kubernetes version, both arches, as a manifest list.
# Names and tags come from `kubeadm config images list`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=../scripts/kubeadm-images.sh
source "${ROOT}/scripts/kubeadm-images.sh"
# shellcheck source=../scripts/enable-fips-go.sh
source "${ROOT}/scripts/enable-fips-go.sh"

K8S_VERSION="${1:?kubernetes version e.g. v1.36.4}"
PREFIX="$(image_prefix)"
WORKDIR="${ROOT}/build/k8s-images/${K8S_VERSION}"
mkdir -p "${WORKDIR}"
# /tmp is a small tmpfs on some hosts. Go compile temps land there by default
# and a Kubernetes build exceeds it while the home disk still has room.
export GOTMPDIR="${WORKDIR}/gotmp"
mkdir -p "${GOTMPDIR}"

apply_fips_env() {
  local govfile="$1"
  enable_fips_go "${govfile}"
  export CGO_ENABLED=0 GOOS=linux
}

git_ref_for_tag() {
  local tag="$1"
  case "${tag}" in
    v*) printf '%s\n' "${tag}" ;;
    *) printf 'v%s\n' "${tag}" ;;
  esac
}

clone() {
  local url="$1" dest="$2" ref="$3"
  if [[ ! -d "${dest}/.git" ]]; then
    git clone --depth 1 --branch "${ref}" "${url}" "${dest}"
  fi
}

k8s_out() {
  local bin="$1" arch="$2"
  printf '%s\n' "${WORKDIR}/kubernetes/_output/local/bin/linux/${arch}/${bin}"
}

# One make for every kubeadm Kubernetes binary. A per-binary make prints only
# the first target and, on failure, aborts the image loop with no message.
build_k8s_bins() {
  local arch="$1"
  shift
  local src="${WORKDIR}/kubernetes" bin
  clone https://github.com/kubernetes/kubernetes.git "${src}" "${K8S_VERSION}"
  apply_fips_env "${src}/.go-version"
  export GOARCH="${arch}"
  printf 'building %s for linux/%s\n' "$*" "${arch}" >&2
  if ! (cd "${src}" && make "$@" KUBE_BUILD_PLATFORMS="linux/${arch}") </dev/null; then
    printf 'make failed for linux/%s\n' "${arch}" >&2
    return 1
  fi
  for bin in "$@"; do
    if [[ ! -x "$(k8s_out "${bin}" "${arch}")" ]]; then
      printf 'missing %s\n' "$(k8s_out "${bin}" "${arch}")" >&2
      return 1
    fi
  done
}

build_etcd() {
  local tag="$1" arch="$2"
  local src="${WORKDIR}/etcd"
  # A failed clone must return. This function runs in a command substitution,
  # where a failing command does not stop the script.
  clone https://github.com/etcd-io/etcd.git "${src}" "$(etcd_git_ref "${tag}")" || return 1
  apply_fips_env "${src}/.go-version"
  export GOARCH="${arch}"
  if [[ ! -f "${src}/.go-version" ]]; then
    enable_fips_go ""
    export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
  fi
  mkdir -p "${WORKDIR}/bin"
  # server/ is its own module. Not ${WORKDIR}/etcd-${arch}: that path is the image context.
  (cd "${src}/server" && go build -o "${WORKDIR}/bin/etcd-${arch}" ./etcdmain) </dev/null || return 1
  printf '%s\n' "${WORKDIR}/bin/etcd-${arch}"
}

build_coredns() {
  local tag="$1" arch="$2"
  local src="${WORKDIR}/coredns"
  clone https://github.com/coredns/coredns.git "${src}" "$(git_ref_for_tag "${tag}")" || return 1
  apply_fips_env "${src}/.go-version"
  export GOARCH="${arch}"
  if [[ ! -f "${src}/.go-version" ]]; then
    enable_fips_go ""
    export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
  fi
  mkdir -p "${WORKDIR}/bin"
  # Not ${WORKDIR}/coredns-${arch}: that path is the image context directory.
  (cd "${src}" && go build -o "${WORKDIR}/bin/coredns-${arch}" .) </dev/null || return 1
  printf '%s\n' "${WORKDIR}/bin/coredns-${arch}"
}

pack_and_push() {
  local ref="$1" binpath="$2" binname="$3" arch="$4"
  local ctx="${WORKDIR}/${binname}-${arch}"
  printf 'packing %s (%s)\n' "${ref}" "${arch}" >&2
  # A previous build may have left a binary at this path. mkdir then fails with "File exists".
  rm -rf "${ctx}"
  mkdir -p "${ctx}"
  cp "${binpath}" "${ctx}/${binname}"
  cat >"${ctx}/Dockerfile" <<EOF
FROM scratch
COPY ${binname} /usr/local/bin/${binname}
ENTRYPOINT ["/usr/local/bin/${binname}"]
EOF
  local tag="${ref}"
  # shellcheck disable=SC2086
  if [[ "$(echo ${ARCHES} | wc -w | tr -d ' ')" -gt 1 ]]; then
    tag="${ref}-${arch}"
  fi
  oci_build --platform="linux/${arch}" --push -t "${tag}" "${ctx}"
}

publish_index() {
  local ref="$1"
  # shellcheck disable=SC2086
  if [[ "$(echo ${ARCHES} | wc -w | tr -d ' ')" -le 1 ]]; then
    return 0
  fi
  local cmd=(crane index append -t "${ref}") a
  for a in ${ARCHES}; do
    cmd+=(-m "${ref}-${a}")
  done
  "${cmd[@]}"
}

copy_pause() {
  local tag="$1"
  echo "retag pause ${tag}"
  crane copy "registry.k8s.io/pause:${tag}" "${PREFIX}/pause:${tag}"
}

main() {
  local list name tag ref bin binpath arch
  prepare_registry_auth
  list="$(kubeadm_image_list "${K8S_VERSION}" "${PREFIX}")"
  mkdir -p "${ROOT}/build"
  printf '%s\n' "${list}" >"${ROOT}/build/images-${K8S_VERSION}.txt"
  local pause
  pause="$(printf '%s\n' "${list}" | parse_image_list "${PREFIX}" | pause_tag_from_list)"
  printf '%s\n' "${pause}" >"${ROOT}/build/pause-tag-${K8S_VERSION}"

  local parsed="${ROOT}/build/images-parsed-${K8S_VERSION}.txt" line
  local -a items=()
  local built_k8s=" "
  printf '%s\n' "${list}" | parse_image_list "${PREFIX}" >"${parsed}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    items+=("${line}")
  done <"${parsed}"

  for line in "${items[@]}"; do
    name="${line%%$'\t'*}"
    tag="${line#*$'\t'}"
    [[ -n "${name}" ]] || continue
    ref="${PREFIX}/${name}:${tag}"
    bin="${name##*/}"
    case "${bin}" in
      pause)
        copy_pause "${tag}"
        ;;
      kube-apiserver | kube-controller-manager | kube-scheduler | kube-proxy | etcd | coredns)
        for arch in ${ARCHES}; do
          case "${bin}" in
            etcd) binpath="$(build_etcd "${tag}" "${arch}")" || exit 1 ;;
            coredns) binpath="$(build_coredns "${tag}" "${arch}")" || exit 1 ;;
            *)
              if [[ "${built_k8s}" != *" ${arch} "* ]]; then
                build_k8s_bins "${arch}" kube-apiserver kube-controller-manager kube-scheduler kube-proxy
                built_k8s+="${arch} "
              fi
              binpath="$(k8s_out "${bin}" "${arch}")"
              ;;
          esac
          pack_and_push "${ref}" "${binpath}" "${bin}" "${arch}"
        done
        publish_index "${ref}"
        ;;
      *)
        echo "kubeadm lists unknown image ${name}:${tag}" >&2
        exit 1
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
