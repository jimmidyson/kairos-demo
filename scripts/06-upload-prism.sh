#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 6 "Upload Ubuntu 24.04 amd64 disk to Prism" \
  "CAPX NutanixMachineTemplate needs a Prism image name." \
  "Prism image ${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64}"

require_env NUTANIX_ENDPOINT
require_env NUTANIX_USER
require_env NUTANIX_PASSWORD

IMAGE_NAME="${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64}"
DISK="${ROOT}/build/ubuntu-24.04-amd64.raw"
export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME="${IMAGE_NAME}"

if [[ -n "${IMAGE_SOURCE_URI:-}" ]]; then
  printf '  creating Prism image %s from IMAGE_SOURCE_URI\n' "${IMAGE_NAME}"
  export IMAGE_NAME IMAGE_SOURCE_URI
  curl -sk -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
    -H 'Content-Type: application/json' \
    "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images" \
    -d "$(python3 -c 'import json,os; print(json.dumps({"spec":{"name":os.environ["IMAGE_NAME"],"resources":{"image_type":"DISK_IMAGE","source_uri":os.environ["IMAGE_SOURCE_URI"]}},"metadata":{"kind":"image"}}))')"
elif [[ -f "${DISK}" ]]; then
  printf '  local disk %s — Prism needs a URL it can GET.\n' "${DISK}"
  printf '  set IMAGE_SOURCE_URI to an HTTP(S) URL of this file, or upload in Prism UI as %s\n' "${IMAGE_NAME}"
  printf '  then export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME=%s\n' "${IMAGE_NAME}"
else
  printf '  no disk at %s and no IMAGE_SOURCE_URI.\n' "${DISK}"
  printf '  upload the OSArtifact output in Prism as %s and export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME\n' "${IMAGE_NAME}"
fi

printf '  using NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME=%s\n' "${IMAGE_NAME}"
step_ok
next_step 7
