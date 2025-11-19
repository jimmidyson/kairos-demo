#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Discover script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

if [ -z "${VERSION:-}" ]; then
  echo "VERSION environment variable is not set"
  exit 1
fi

# Build base images for both architectures with arch suffix in tag
echo "Building base images..."
for arch in amd64 arm64; do
  docker buildx build --progress=plain \
    --platform="linux/${arch}" \
    --load \
    --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.base" \
    --build-arg=VERSION="${VERSION}" \
    --tag="base-image:${VERSION}-${arch}" \
    "${SCRIPT_DIR}"
done

declare -rA containerd_config=(
    ["version"]="2.1.4"
    ["build_arg"]="CONTAINERD_VERSION"
)

declare -rA runc_config=(
    ["version"]="1.3.2"
    ["build_arg"]="RUNC_VERSION"
)

declare -rA cniplugins_config=(
    ["version"]="1.8.0"
    ["build_arg"]="CNI_PLUGINS_VERSION"
)

readonly AURORABOOT_VERSION="${AURORABOOT_VERSION:-v0.13.0}"

# Build containerd and runc images for both architectures
for component in containerd runc cniplugins; do
    for arch in amd64 arm64; do
      mkdir -p "${SCRIPT_DIR}/outputs/${arch}"

      echo "Building ${component} for ${arch}..."

      declare -n config="${component}_config"

      docker buildx build --progress=plain \
        --platform="linux/${arch}" \
        --load \
        --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.${component}" \
        --build-arg="${config["build_arg"]}=${config["version"]}" \
        --tag="${component}:${config["version"]}-${arch}" \
        "${SCRIPT_DIR}"

      rm -f "${SCRIPT_DIR}/outputs/${arch}/${component}-${config["version"]}"*
      docker container run \
        --rm \
        --mount="type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock,readonly" \
        --mount="type=bind,src=${SCRIPT_DIR}/keys,dst=/keys,readonly" \
        --mount="type=bind,src=${SCRIPT_DIR}/outputs/${arch},dst=/build" \
        "quay.io/kairos/auroraboot:${AURORABOOT_VERSION}" \
        sysext \
        --private-key=/keys/code_signing_key.key --certificate=/keys/code_signing_cert.pem \
        --output=/build \
        --arch=${arch} \
        "${component}-${config["version"]}" \
        "${component}:${config["version"]}-${arch}"
    done
done

if [ -z "${UBUNTU_PRO_TOKEN:-}" ]; then
  echo "UBUNTU_PRO_TOKEN environment variable is not set"
  exit 1
fi

echo "Building final image..."
for arch in amd64 arm64; do
  docker buildx build --progress=plain \
    --platform="linux/${arch}" \
    --load \
    --file="${SCRIPT_DIR}/dockerfiles/Dockerfile.final" \
    --secret="id=ubuntu-pro-token,env=UBUNTU_PRO_TOKEN" \
    --build-arg="BASE_IMAGE_VERSION=${VERSION}" \
    --tag="final-image:${VERSION}-${arch}" "${SCRIPT_DIR}"

  docker container run \
    --rm \
    --platform="linux/${arch}" \
    --mount="type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock,readonly" \
    --mount="type=bind,src=${SCRIPT_DIR},dst=/build" \
    "quay.io/kairos/auroraboot:${AURORABOOT_VERSION}" \
    --debug \
    --set="disable_http_server=true" \
    --set="disable_netboot=true" \
    build-iso \
    --output=/build/outputs/ \
    --cloud-config=/build/buld-cloud-config.yaml \
    "oci:final-image:${VERSION}-${arch}"
done


