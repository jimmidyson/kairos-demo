#!/usr/bin/env bash

set -euxo pipefail
IFS=$'\n\t'

# Discover script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly PLATFORM="${PLATFORM:-linux/amd64}"
function print() {
  if [ -t 0 ]; then
    prefix='\033[34;1m▶\033[0m'
  else
    prefix='=>'
  fi
  printf "${prefix} ${1}\n"
}

export CONTAINERD_VERSION="2.1.4"
export KUBERNETES_VERSION="1.34.1"
export RUNC_VERSION="1.3.2"
export CRICTL_VERSION="1.34.0"
export CNI_PLUGINS_VERSION="1.8.0"

ISO_NAME="bootstrap"

rm -rf "$SCRIPT_DIR"/build
mkdir -p "$SCRIPT_DIR"/build
mkdir -p "$SCRIPT_DIR"/build/bundles


print "Building CIS hardened base image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=docker \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.base" \
  --build-arg=VERSION="${VERSION}" \
	--secret="id=ubuntu-pro-token,env=UBUNTU_PRO_TOKEN" \
  --tag="${OCI_REGISTRY}/base-image:${VERSION}" \
  "${SCRIPT_DIR}"

print "Building final image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=docker \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.final" \
  --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
  --build-arg="BASE_IMAGE_REGISTRY=${OCI_REGISTRY}" \
  --tag="${OCI_REGISTRY}/final-image:${VERSION}" "${SCRIPT_DIR}"

print "Building airgap bundle..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=docker \
  --build-arg="KUBERNETES_VERSION=${KUBERNETES_VERSION}" \
  --file="${SCRIPT_DIR}/bundles/kubernetes-images/Dockerfile" \
  --tag="nkp/kubernetes-images:v${KUBERNETES_VERSION}" "${SCRIPT_DIR}/bundles/kubernetes-images"
docker save "nkp/kubernetes-images:v${KUBERNETES_VERSION}" -o build/bundles/kubernetes-images-v${KUBERNETES_VERSION}.tar

print "Building kubernetes systemd extension..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=docker \
  --file="${SCRIPT_DIR}/bundles/kubernetes/Dockerfile" \
  --build-arg="CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION}" \
  --build-arg="CONTAINERD_VERSION=${CONTAINERD_VERSION}" \
  --build-arg="RUNC_VERSION=${RUNC_VERSION}" \
  --build-arg="KUBERNETES_VERSION=${KUBERNETES_VERSION}" \
  --build-arg="CRICTL_VERSION=${CRICTL_VERSION}" \
  --tag="nkp/kubernetes:v${KUBERNETES_VERSION}" "${SCRIPT_DIR}/bundles/kubernetes"
docker save "nkp/kubernetes:v${KUBERNETES_VERSION}" -o build/bundles/kubernetes-v${KUBERNETES_VERSION}.tar

print "Building cloud config..."
cat "$SCRIPT_DIR"/cloud-config.yaml | envsubst > "$SCRIPT_DIR/build/cloud-config.yaml"

docker run --platform "$PLATFORM" --rm -ti \
  -v "$SCRIPT_DIR/build/cloud-config.yaml:/config.yaml" \
  -v "$SCRIPT_DIR/build":/tmp/auroraboot \
  -v "$SCRIPT_DIR/build/bundles":/tmp/bundles \
  -v /var/run/docker.sock:/var/run/docker.sock \
  quay.io/kairos/auroraboot \
  --set "container_image=${OCI_REGISTRY}/final-image:${VERSION}" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "iso.data=/tmp/bundles" \
  --set "iso.override_name=${ISO_NAME}" \
  --set "state_dir=/tmp/auroraboot" \
  --cloud-config /config.yaml
