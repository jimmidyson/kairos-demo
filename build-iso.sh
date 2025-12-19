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
export KUBERNETES_IMAGES_VERSION="v1.34.1"
ISO_NAME="bootstrap"

print "Building CIS hardened base image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.base" \
  --build-arg=VERSION="${VERSION}" \
	--secret="id=ubuntu-pro-token,env=UBUNTU_PRO_TOKEN" \
  --tag="${OCI_REGISTRY}/base-image:${VERSION}" \
  "${SCRIPT_DIR}"

print "Building final image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.final" \
  --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
  --build-arg="BASE_IMAGE_REGISTRY=${OCI_REGISTRY}" \
  --tag="${OCI_REGISTRY}/final-image:${VERSION}" "${SCRIPT_DIR}"

print "Building airgap bundle..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=docker \
  --file="${SCRIPT_DIR}/bundles/kubernetes-images/Dockerfile" \
  --tag="nkp/kubernetes-images:${KUBERNETES_IMAGES_VERSION}" "${SCRIPT_DIR}/bundles/kubernetes-images"

rm -rf "$SCRIPT_DIR"/build
mkdir -p "$SCRIPT_DIR"/build

mkdir -p "$SCRIPT_DIR"/build/bundles
docker save "nkp/kubernetes-images:${KUBERNETES_IMAGES_VERSION}" -o build/bundles/kubernetes-images-${KUBERNETES_IMAGES_VERSION}.tar

cat "$SCRIPT_DIR"/cloud-config.yaml | envsubst > "$SCRIPT_DIR/build/cloud-config.yaml"

docker run --platform "$PLATFORM" --rm -ti \
  -v "$SCRIPT_DIR/build/cloud-config.yaml:/config.yaml" \
  -v "$SCRIPT_DIR/build":/tmp/auroraboot \
  -v "$SCRIPT_DIR/build/bundles":/tmp/bundles \
  quay.io/kairos/auroraboot \
  --set "container_image=${OCI_REGISTRY}/final-image:${VERSION}" \
  --set "kubernetes_images_version=${KUBERNETES_IMAGES_VERSION}" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "iso.data=/tmp/bundles" \
  --set "iso.override_name=${ISO_NAME}" \
  --set "state_dir=/tmp/auroraboot" \
  --cloud-config /config.yaml
