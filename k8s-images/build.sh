#!/usr/bin/env bash
# Build FIPS kubeadm static-pod images and retag pause into ${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX}.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

K8S_VERSION="${1:?kubernetes version e.g. v1.36.4}"
ARCH="${2:?amd64|arm64}"
PREFIX="$(image_prefix)"
WORKDIR="${ROOT}/build/k8s-images/${K8S_VERSION}-${ARCH}"
mkdir -p "${WORKDIR}"

export GOFIPS140=certified CGO_ENABLED=0 GOOS=linux GOARCH="${ARCH}"

build_k8s_bin() {
  local bin="$1"
  local src="${WORKDIR}/kubernetes"
  if [[ ! -d "${src}/.git" ]]; then
    git clone --depth 1 --branch "${K8S_VERSION}" https://github.com/kubernetes/kubernetes.git "${src}"
  fi
  (cd "${src}" && make "${bin}" KUBE_BUILD_PLATFORMS="linux/${ARCH}")
}

pack_bin() {
  local name="$1" binpath="$2"
  local ctx="${WORKDIR}/${name}"
  mkdir -p "${ctx}"
  cat >"${ctx}/Dockerfile" <<EOF
FROM scratch
COPY ${name} /usr/local/bin/${name}
ENTRYPOINT ["/usr/local/bin/${name}"]
EOF
  cp "${binpath}" "${ctx}/${name}"
  docker buildx build --platform="linux/${ARCH}" --push -t "${PREFIX}/${name}:${K8S_VERSION}" "${ctx}"
}

echo "building kubernetes control-plane binaries ${K8S_VERSION} ${ARCH} with GOFIPS140=certified"
for b in kube-apiserver kube-controller-manager kube-scheduler kube-proxy; do
  build_k8s_bin "${b}"
  binpath="${WORKDIR}/kubernetes/_output/local/go/bin/linux_${ARCH}/${b}"
  if [[ ! -x "${binpath}" ]]; then
    binpath="${WORKDIR}/kubernetes/_output/bin/${b}"
  fi
  pack_bin "${b}" "${binpath}"
done

# etcd version kubeadm pins — query from k8s source if present, else 3.5.21
ETCD_VERSION="${ETCD_VERSION:-3.5.21}"
if [[ ! -d "${WORKDIR}/etcd/.git" ]]; then
  git clone --depth 1 --branch "v${ETCD_VERSION}" https://github.com/etcd-io/etcd.git "${WORKDIR}/etcd"
fi
(cd "${WORKDIR}/etcd" && go build -o etcd ./cmd/etcd)
pack_bin etcd "${WORKDIR}/etcd/etcd"

COREDNS_VERSION="${COREDNS_VERSION:-1.12.1}"
if [[ ! -d "${WORKDIR}/coredns/.git" ]]; then
  git clone --depth 1 --branch "v${COREDNS_VERSION}" https://github.com/coredns/coredns.git "${WORKDIR}/coredns"
fi
(cd "${WORKDIR}/coredns" && go build -o coredns .)
pack_bin coredns "${WORKDIR}/coredns/coredns"

echo "retag pause ${PAUSE_IMAGE_TAG}"
crane copy "registry.k8s.io/pause:${PAUSE_IMAGE_TAG}" "${PREFIX}/pause:${PAUSE_IMAGE_TAG}" --platform="linux/${ARCH}"
