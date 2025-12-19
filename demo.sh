#!/usr/bin/env bash

set -euo pipefail
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

print "Building bootstrap image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.bootstrap" \
  --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
  --build-arg="BASE_IMAGE_REGISTRY=${OCI_REGISTRY}" \
  --tag="${OCI_REGISTRY}/bootstrap-image:${VERSION}" "${SCRIPT_DIR}"

print "Building final image..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=registry \
  --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.final" \
  --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
  --build-arg="BASE_IMAGE_REGISTRY=${OCI_REGISTRY}" \
  --tag="${OCI_REGISTRY}/final-image:${VERSION}" "${SCRIPT_DIR}"


# print "Building containerd image bundle..."
# docker buildx build --progress=plain \
#   --platform="${PLATFORM}" \
#   --pull \
#   --output=type=registry \
#   --build-arg="CONTAINERD_VERSION=${CONTAINERD_VERSION}" \
#   --file="${SCRIPT_DIR}/bundles/containerd/Dockerfile" \
#   --tag="${OCI_REGISTRY}/containerd-image:${CONTAINERD_VERSION}" "${SCRIPT_DIR}/bundles/containerd"

print "Building airgap bundle..."
docker buildx build --progress=plain \
  --platform="${PLATFORM}" \
  --pull \
  --output=type=docker \
  --file="${SCRIPT_DIR}/bundles/kubernetes-images/Dockerfile" \
  --tag="nkp/kubernetes-images:v1.34.1" "${SCRIPT_DIR}/bundles/kubernetes-images"

if [ ! -d data ]; then
 mkdir data
fi

pushd data
    docker save "nkp/kubernetes-images:v1.34.1" -o kubernetes-images-v1.34.1.tar
popd

rm -rf "$SCRIPT_DIR"/build
mkdir -p "$SCRIPT_DIR"/build
cat "$SCRIPT_DIR"/cloud-config.yaml | envsubst > "$SCRIPT_DIR/build/cloud-config.yaml"
docker run --platform "$PLATFORM" --rm -ti \
  -v "$SCRIPT_DIR/build/cloud-config.yaml:/config.yaml" \
  -v "$SCRIPT_DIR/build":/tmp/auroraboot \
  -v $PWD/data:/tmp/data \
  quay.io/kairos/auroraboot \
  --set "container_image=${OCI_REGISTRY}/final-image:${VERSION}" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "iso.data=/tmp/data" \
  --set "state_dir=/tmp/auroraboot" \
  --cloud-config /config.yaml

# Copy or override the bootstrap.iso file
cp "$SCRIPT_DIR/build/auroraboot/kairos-*.iso" "$SCRIPT_DIR/bootstrap.iso"