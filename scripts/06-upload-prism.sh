#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=prism.sh
source "${ROOT}/scripts/prism.sh"

IMAGE_NAME="${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:-kairos-ubuntu-24.04-amd64-$(date -u +%Y%m%d%H%M%S)}"

step_start 6 "Upload Ubuntu 24.04 amd64 disk to Prism" \
  "CAPX NutanixMachineTemplate looks up the timestamped Prism image by name." \
  "Prism image ${IMAGE_NAME}"

require_env NUTANIX_ENDPOINT
require_env NUTANIX_USER
require_env NUTANIX_PASSWORD

if ! prism_ensure_image "${IMAGE_NAME}"; then
  step_fail "Prism image ${IMAGE_NAME} is not COMPLETE. Set IMAGE_SOURCE_URI to an HTTP(S) URL Prism can GET, or NUTANIX_CA_FILE for the Prism CA (NUTANIX_INSECURE=1 skips TLS verify)."
  exit 1
fi

printf '%s\n' "${IMAGE_NAME}" >"${ROOT}/build/prism-image-name"
printf '  uploaded Prism image: %s\n' "${IMAGE_NAME}"
step_ok
next_step 7
