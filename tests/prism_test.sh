#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
# shellcheck source=../scripts/prism.sh
source "${ROOT}/scripts/prism.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q -- '--insecure' "${ROOT}/scripts/prism.sh" || fail "insecure must be opt-in"
grep -q 'NUTANIX_INSECURE' "${ROOT}/scripts/prism.sh" || fail "NUTANIX_INSECURE gate"
# The default curl line must not pass -k / --insecure unconditionally.
if grep -E 'curl .*(-k|--insecure)' "${ROOT}/scripts/prism.sh" | grep -v 'NUTANIX_INSECURE' >/dev/null; then
  fail "curl must not disable TLS unless NUTANIX_INSECURE=1"
fi
grep -q -- '--config' "${ROOT}/scripts/prism.sh" || fail "credentials go in a curl config file"
grep -q 'prism_ensure_image' "${ROOT}/scripts/06-upload-prism.sh" || fail "step 6 must wait for the image"
grep -q 'prism_delete_image' "${ROOT}/scripts/10-destroy.sh" || fail "step 10 must delete the image"

found_uuid=""
created_file="$(mktemp)"
trap 'rm -f "${created_file}"' EXIT
prism_find_image() { printf '%s\n' "${found_uuid}"; }
# prism_ensure_image captures this in a command substitution, so the URI
# has to be recorded in a file, not a shell variable.
prism_create_image() { printf '%s\n' "$2" >"${created_file}"; printf 'new-uuid\n'; }
prism_wait_image() { return 0; }

found_uuid=$'abc\tCOMPLETE'
IMAGE_SOURCE_URI=""
prism_ensure_image "kairos" || fail "existing COMPLETE image should succeed"

found_uuid=""
if prism_ensure_image "kairos"; then
  fail "missing image without IMAGE_SOURCE_URI must fail"
fi
IMAGE_SOURCE_URI="http://example.test/disk.raw"
prism_ensure_image "kairos" || fail "create path"
[[ "$(cat "${created_file}")" == "http://example.test/disk.raw" ]] || fail "create uri $(cat "${created_file}")"

export NUTANIX_ENDPOINT=prism.example NUTANIX_USER=admin NUTANIX_PASSWORD='p@ss:"word'
export NUTANIX_CCM_REPO=https://charts.example/ccm NUTANIX_CCM_CHART=nutanix-cloud-provider
ccm="$(python3 "${ROOT}/scripts/render_ccm.py")"
printf '%s\n' "${ccm}" | grep -q 'prismCentral:' || fail "ccm values"
printf '%s\n' "${ccm}" | grep -q 'p@ss:\\"word' || fail "password must be quoted: ${ccm}"
printf '%s\n' "${ccm}" | grep -q 'charts.example/ccm' || fail "ccm repo"

echo "ok prism_test"
