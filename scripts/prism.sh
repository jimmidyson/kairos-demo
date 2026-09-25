#!/usr/bin/env bash
# Prism Central v4 image and Objects helpers. Source this; callers own set -e.
# NUTANIX_OBJECTS_REGION defaults to us-east-1 because Prism Objects accepts
# any signing region but AWS CLI requires one for SigV4.

prism_endpoint() {
  local ep="${NUTANIX_ENDPOINT}"
  ep="${ep#https://}"
  ep="${ep#http://}"
  ep="${ep%%/*}"
  case "${ep}" in
    *:*) printf '%s\n' "${ep}" ;;
    *) printf '%s:%s\n' "${ep}" "${NUTANIX_PORT:-9440}" ;;
  esac
}

prism_v4_base() {
  printf 'https://%s/api/vmm/v4.0\n' "$(prism_endpoint)"
}

prism_objects_endpoint() {
  local ep="${NUTANIX_OBJECTS_ENDPOINT:-}"
  if [[ -z "${ep}" ]]; then
    ep="https://$(prism_endpoint)/api/prism/v4.0/objects/"
  fi
  [[ "${ep}" == http://* || "${ep}" == https://* ]] || ep="https://${ep}"
  printf '%s\n' "${ep%/}/"
}

prism_objects_region() {
  printf '%s\n' "${NUTANIX_OBJECTS_REGION:-us-east-1}"
}

# curl with credentials in a mode-600 config file, not on argv.
# NUTANIX_CA_FILE verifies TLS. NUTANIX_INSECURE=1 skips verification.
prism_curl() {
  local cfg
  require_env NUTANIX_ENDPOINT
  require_env NUTANIX_USER
  require_env NUTANIX_PASSWORD
  cfg="$(mktemp)"
  chmod 600 "${cfg}"
  if ! NUTANIX_USER="${NUTANIX_USER}" NUTANIX_PASSWORD="${NUTANIX_PASSWORD}" python3 - "${cfg}" <<'PY'
import os, sys
path = sys.argv[1]
def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')
user = os.environ["NUTANIX_USER"]
pw = os.environ["NUTANIX_PASSWORD"]
with open(path, "w") as f:
    f.write('user = "%s:%s"\n' % (esc(user), esc(pw)))
PY
  then
    rm -f "${cfg}"
    return 1
  fi
  # Never expand an empty array: bash 3.2 + set -u treats "${ca[@]}" as unbound.
  # curl failure must still delete the config; it contains the password.
  local cmd=(curl --config "${cfg}" --fail-with-body --silent --show-error)
  if [[ "${NUTANIX_INSECURE:-}" == "1" ]]; then
    cmd+=(--insecure)
  elif [[ -n "${NUTANIX_CA_FILE:-}" ]]; then
    cmd+=(--cacert "${NUTANIX_CA_FILE}")
  fi
  cmd+=("$@")
  local tmp_out rc=0
  tmp_out="$(mktemp)"
  "${cmd[@]}" >"$tmp_out" || rc=$?
  rm -f "${cfg}"
  if (( rc != 0 )); then
    cat "$tmp_out" >&2
    rm -f "$tmp_out"
    return "${rc:-1}"
  fi
  cat "$tmp_out"
  rm -f "$tmp_out"
  return 0
}

# Upload a local disk into Prism Objects using its S3-compatible API.
prism_upload_object() {
  local file="$1" key="$2" access secret region
  [[ -s "${file}" ]] || { printf 'missing or empty image file: %s\n' "${file}" >&2; return 1; }
  command -v aws >/dev/null 2>&1 || { printf 'aws CLI is required for Prism Objects upload\n' >&2; return 1; }
  access="${NUTANIX_OBJECTS_ACCESS_KEY:-}"
  secret="${NUTANIX_OBJECTS_SECRET_KEY:-}"
  if [[ -z "${access}" || -z "${secret}" ]]; then
    local auth_b64 objects_user="${NUTANIX_USERNAME:-${NUTANIX_USER}}"
    [[ -n "${objects_user}" ]] || { printf 'NUTANIX_USERNAME or NUTANIX_USER is required\n' >&2; return 1; }
    auth_b64="$(printf '%s:%s' "${objects_user}" "${NUTANIX_PASSWORD}" | base64 | tr -d '\r\n')"
    access="${auth_b64}"
    secret="${auth_b64}"
  fi
  region="$(prism_objects_region)"
  local size
  size="$(stat -c '%s' "${file}" 2>/dev/null || stat -f '%z' "${file}")"
  local endpoint="$(prism_objects_endpoint)" digest
  digest="$(sha256sum "${file}" | awk '{print $1}')"
  printf '  uploading object %s to %s/%s (%s bytes)\n' "${file}" "${NUTANIX_OBJECTS_BUCKET:-vmm-images}" "${key}" "${size}" >&2
  printf '  upload endpoint: %s\n' "${endpoint}" >&2
  # Pass credentials and progress flags explicitly, without inheriting an AWS
  # profile or config that could redirect this upload or use SSO.
  env AWS_ACCESS_KEY_ID="${access}" \
      AWS_SECRET_ACCESS_KEY="${secret}" \
      AWS_DEFAULT_REGION="${region}" \
      AWS_CONFIG_FILE=<(cat <<'EOF'
[default]
s3 =
    max_concurrent_requests = 1
    multipart_chunksize = 64MB
    multipart_threshold = 64MB
EOF
) \
      AWS_RETRY_MODE=adaptive \
      AWS_MAX_ATTEMPTS=12 \
      aws s3 cp "${file}" "s3://${NUTANIX_OBJECTS_BUCKET:-vmm-images}/${key}" \
        --progress-multiline --progress-frequency 5 \
        --endpoint-url "${endpoint}" \
        --metadata "sha256=${digest}" \
        $(if [[ "${NUTANIX_INSECURE:-}" == 1 ]]; then printf '%s' '--no-verify-ssl'; fi)
  printf '  object upload complete: %s\n' "${key}" >&2
}

# Prints "external-id<TAB>state" or nothing. v4 list responses contain data[].
prism_find_image() {
  local name="$1"
  # Do not send $filter here: Prism versions differ in their v4 filter
  # grammar. The response is capped and matched locally by exact name.
  prism_curl "$(prism_v4_base)/content/images?%24limit=50" \
    | NAME="${name}" python3 -c '
import json, os, sys
name = os.environ["NAME"]
data = json.load(sys.stdin)
raw = data.get("data") or []
if isinstance(raw, dict):
    for key, value in raw.items():
        if key.startswith("List<"):
            raw = value
            break
    else:
        raw = [raw]
items = raw if isinstance(raw, list) else []
for item in items:
    value = item.get("value", item) if isinstance(item, dict) else {}
    if value.get("name") == name or value.get("displayName") == name:
        ext = value.get("extId") or value.get("id") or ""
        state = value.get("state") or value.get("status") or "COMPLETE"
        if ext:
            print(ext + "\\t" + state)
        break
'
}

prism_create_image() {
  local name="$1" key="$2" request_id="${3:-}" body task
  body="$(NAME="${name}" KEY="${key}" python3 -c 'import json,os; print(json.dumps({"name":os.environ["NAME"],"type":"DISK_IMAGE","source":{"$objectType":"vmm.v4.content.ObjectsLiteSource","key":os.environ["KEY"]}}))')"
  printf '  creating Prism image %s from object %s\n' "${name}" "${key}" >&2
  printf '  image request: %s\n' "${body}" >&2
  task="$(prism_curl -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' ${request_id:+-H "NTNX-Request-Id: $request_id"} "$(prism_v4_base)/content/images" -d "${body}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); v=(d.get("data") or {}).get("value",d.get("data") or {}); print(v.get("extId") or "")')"
  [[ -n "${task}" ]] || return 1
  printf '  image creation task: %s\n' "${task}" >&2
  prism_wait_task "${task}" || return 1
  printf '  image creation task complete: %s\n' "${task}" >&2
  prism_curl "https://$(prism_endpoint)/api/prism/v4.0/config/tasks/${task}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); v=(d.get("data") or {}).get("value",d.get("data") or {}); a=v.get("entitiesAffected") or []; print((a[0].get("extId") if a else "") or "")'
}

prism_image_state() {
  local uuid="$1"
  prism_curl "$(prism_v4_base)/content/images/${uuid}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); v=(d.get("data") or {}).get("value",d.get("data") or {}); print(v.get("state") or v.get("status") or ("COMPLETE" if v.get("sizeBytes",0) else ""))'
}

prism_task_state() {
  local uuid="$1"
  prism_curl "https://$(prism_endpoint)/api/prism/v4.0/config/tasks/${uuid}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); v=(d.get("data") or {}).get("value",d.get("data") or {}); print(v.get("status") or "")'
}

prism_wait_task() {
  local uuid="$1" state i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    state="$(prism_task_state "${uuid}")"
    case "${state}" in
      SUCCEEDED) return 0 ;;
      FAILED|CANCELED)
        printf 'Prism task %s entered %s\n' "${uuid}" "${state}" >&2
        return 1
        ;;
    esac
    sleep 10
  done
  printf 'Prism task %s did not complete\n' "${uuid}" >&2
  return 1
}

prism_wait_image() {
  local uuid="$1" state i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    state="$(prism_image_state "${uuid}")"
    case "${state}" in
      COMPLETE|SUCCEEDED) return 0 ;;
      ERROR|FAILED)
        printf 'Prism image %s entered %s\n' "${uuid}" "${state}" >&2
        return 1
        ;;
    esac
    sleep 10
  done
  printf 'Prism image %s did not become COMPLETE\n' "${uuid}" >&2
  return 1
}

prism_ensure_image() {
  local name="$1" found uuid state
  found="$(prism_find_image "${name}" || true)"
  uuid="${found%%$'\t'*}"
  if [[ "${found}" == *$'\t'* ]]; then
    state="${found#*$'\t'}"
  else
    state=""
  fi
  if [[ -n "${uuid}" ]]; then
    if [[ "${state}" == "COMPLETE" ]]; then
      return 0
    fi
    if [[ "${state}" == "ERROR" ]]; then
      printf 'Prism image %s (%s) is ERROR\n' "${name}" "${uuid}" >&2
      return 1
    fi
    prism_wait_image "${uuid}"
    return
  fi
  local file="${FACTORY_ROOT}/build/ubuntu-24.04-amd64.raw"
  local key="${NUTANIX_OBJECTS_KEY:-kairos/${name}.raw}"
  local digest req_id
  digest="$(sha256sum "${file}" | awk '{print $1}')"
  req_id="$(python3 -c 'import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))' "${digest}")"
  prism_upload_object "${file}" "${key}" || return 1
  uuid="$(prism_create_image "${name}" "${key}" "${req_id}")"
  [[ -n "${uuid}" ]] || return 1
  prism_wait_image "${uuid}"
}

prism_delete_image() {
  local name="$1" found uuid
  found="$(prism_find_image "${name}" || true)"
  uuid="${found%%$'\t'*}"
  [[ -n "${uuid}" ]] || return 0
  prism_curl -X DELETE "$(prism_v4_base)/content/images/${uuid}" || {
    printf 'Prism image %s (%s) was already gone or delete failed\n' "${name}" "${uuid}" >&2
    return 0
  }
}
