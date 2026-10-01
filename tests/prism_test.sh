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
raw="$(mktemp)"
printf 'x' >"${raw}"
export PRISM_IMAGE_FILE="${raw}"
trap 'rm -f "${created_file}" "${raw}"' EXIT
unset NUTANIX_OBJECTS_KEY
prism_find_image() { printf '%s\n' "${found_uuid}"; }
prism_upload_object() { return 0; }
prism_create_image() { printf '%s %s\n' "$2" "$3" >"${created_file}"; printf 'new-uuid\n'; }
prism_wait_image() { return 0; }

found_uuid=$'abc\tCOMPLETE'
prism_ensure_image "kairos" || fail "existing COMPLETE image should succeed"

found_uuid=$'abc\tERROR'
if prism_ensure_image "kairos"; then
  fail "ERROR image should fail"
fi

found_uuid=""
prism_ensure_image "kairos" || fail "create path"
digest="$(sha256sum "${raw}" | awk '{print $1}')"
[[ "$(cat "${created_file}")" == "kairos/kairos.raw $(uuid5_url "${digest}")" ]] \
  || fail "create args $(cat "${created_file}")"

cfg="$(mktemp)"
prism_curl_user_config 'a\b' 'p@ss:"word' >"${cfg}"
[[ "$(cat "${cfg}")" == 'user = "a\\b:p@ss:\"word"' ]] || fail "curl config $(cat "${cfg}")"
rm -f "${cfg}"

match="$(printf '%s\n' '{"data":{"List<vmm.v4.content.Image>":[{"value":{"name":"kairos","extId":"id-1"}}]}}' | prism_match_image kairos)"
[[ "${match}" == $'id-1\tCOMPLETE' ]] || fail "list match: ${match}"
by_display="$(printf '%s\n' '{"data":[{"displayName":"kairos","id":"id-2","status":"ACTIVE"}]}' | prism_match_image kairos)"
[[ "${by_display}" == $'id-2\tACTIVE' ]] || fail "displayName match: ${by_display}"
none="$(printf '%s\n' '{"data":[]}' | prism_match_image kairos)"
[[ -z "${none}" ]] || fail "missing image should print nothing: ${none}"

ext="$(printf '%s\n' '{"data":{"value":{"extId":"task-1"}}}' | prism_ext_id)"
[[ "${ext}" == "task-1" ]] || fail "extId: ${ext}"
affected="$(printf '%s\n' '{"data":{"value":{"entitiesAffected":[{"extId":"img-1"}]}}}' | prism_affected_ext_id)"
[[ "${affected}" == "img-1" ]] || fail "affected: ${affected}"
state="$(printf '%s\n' '{"data":{"sizeBytes":12}}' | prism_image_state_value)"
[[ "${state}" == "COMPLETE" ]] || fail "sizeBytes state: ${state}"
queued="$(printf '%s\n' '{"data":{"state":"","status":"QUEUED"}}' | prism_image_state_value)"
[[ "${queued}" == "QUEUED" ]] || fail "empty state falls through: ${queued}"
status="$(printf '%s\n' '{"data":{"value":{"status":"SUCCEEDED"}}}' | prism_task_status)"
[[ "${status}" == "SUCCEEDED" ]] || fail "task status: ${status}"
[[ "$(uuid5_url abc)" == "68661508-f3c4-55b4-945d-ae2b4dfe5db4" ]] || fail "uuid5"

export NUTANIX_ENDPOINT=prism.example NUTANIX_USER=admin NUTANIX_PASSWORD='p@ss:"word'
export NUTANIX_CCM_REPO=https://charts.example/ccm NUTANIX_CCM_CHART=nutanix-cloud-provider
ccm="$(bash "${ROOT}/scripts/render_ccm.sh")"
printf '%s\n' "${ccm}" | grep -q 'prismCentral:' || fail "ccm values"
printf '%s\n' "${ccm}" | grep -q 'p@ss:\\"word' || fail "password must be quoted: ${ccm}"
printf '%s\n' "${ccm}" | grep -q 'charts.example/ccm' || fail "ccm repo"

echo "ok prism_test"
