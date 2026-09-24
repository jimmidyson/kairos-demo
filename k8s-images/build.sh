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

build_k8s_bin() {
  local bin="$1" arch="$2"
  local src="${WORKDIR}/kubernetes"
  clone https://github.com/kubernetes/kubernetes.git "${src}" "${K8S_VERSION}"
  apply_fips_env "${src}/.go-version"
  export GOARCH="${arch}"
  (cd "${src}" && make "${bin}" KUBE_BUILD_PLATFORMS="linux/${arch}")
  local binpath="${src}/_output/local/go/bin/linux_${arch}/${bin}"
  if [[ ! -x "${binpath}" ]]; then
    binpath="${src}/_output/bin/${bin}"
  fi
  printf '%s\n' "${binpath}"
}

build_etcd() {
  local tag="$1" arch="$2"
  local src="${WORKDIR}/etcd"
  clone https://github.com/etcd-io/etcd.git "${src}" "$(git_ref_for_tag "${tag}")"
  apply_fips_env "${src}/.go-version"
  export GOARCH="${arch}"
  if [[ ! -f "${src}/.go-version" ]]; then
    enable_fips_go ""
    export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
  fi
  (cd "${src}" && go build -o "${WORKDIR}/etcd-${arch}" ./cmd/etcd)
  printf '%s\n' "${WORKDIR}/etcd-${arch}"
}

build_coredns() {
  local tag="$1" arch="$2"
  local src="${WORKDIR}/coredns"
  clone https://github.com/coredns/coredns.git "${src}" "$(git_ref_for_tag "${tag}")"
  apply_fips_env "${src}/.go-version"
  export GOARCH="${arch}"
  if [[ ! -f "${src}/.go-version" ]]; then
    enable_fips_go ""
    export CGO_ENABLED=0 GOOS=linux GOARCH="${arch}"
  fi
  (cd "${src}" && go build -o "${WORKDIR}/coredns-${arch}" .)
  printf '%s\n' "${WORKDIR}/coredns-${arch}"
}

pack_and_push() {
  local ref="$1" binpath="$2" binname="$3" arch="$4"
  local ctx="${WORKDIR}/${binname}-${arch}"
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

  while IFS=$'\t' read -r name tag; do
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
            etcd) binpath="$(build_etcd "${tag}" "${arch}")" ;;
            coredns) binpath="$(build_coredns "${tag}" "${arch}")" ;;
            *) binpath="$(build_k8s_bin "${bin}" "${arch}")" ;;
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
  done < <(printf '%s\n' "${list}" | parse_image_list "${PREFIX}")
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
