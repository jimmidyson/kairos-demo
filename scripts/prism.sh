#!/usr/bin/env bash
# Prism v3 image helpers. Source this; callers own set -e.

prism_endpoint() {
  local ep="${NUTANIX_ENDPOINT}"
  ep="${ep#https://}"
  ep="${ep#http://}"
  ep="${ep%%/*}"
  case "${ep}" in
    *:*) printf '%s\n' "${ep}" ;;
    *) printf '%s:9440\n' "${ep}" ;;
  esac
}

prism_base() {
  printf 'https://%s/api/nutanix/v3\n' "$(prism_endpoint)"
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
  local cmd=(curl --config "${cfg}" --fail --silent --show-error)
  if [[ "${NUTANIX_INSECURE:-}" == "1" ]]; then
    cmd+=(--insecure)
  elif [[ -n "${NUTANIX_CA_FILE:-}" ]]; then
    cmd+=(--cacert "${NUTANIX_CA_FILE}")
  fi
  cmd+=("$@")
  local rc=0
  "${cmd[@]}" || rc=$?
  rm -f "${cfg}"
  return "${rc}"
}

# Prints "uuid<TAB>state" or nothing.
prism_find_image() {
  local name="$1" body
  body="$(NAME="${name}" python3 -c 'import json,os; print(json.dumps({"kind":"image","offset":0,"length":50,"filter":"name=="+os.environ["NAME"]}))')"
  prism_curl -X POST -H 'Content-Type: application/json' "$(prism_base)/images/list" -d "${body}" \
    | NAME="${name}" python3 -c '
import json, os, sys
name = os.environ["NAME"]
data = json.load(sys.stdin)
for e in data.get("entities") or []:
    spec = e.get("spec") or {}
    status = e.get("status") or {}
    if spec.get("name") == name or status.get("name") == name:
        uuid = (e.get("metadata") or {}).get("uuid") or ""
        state = status.get("state") or ""
        if uuid:
            sys.stdout.write(uuid + "\t" + state + "\n")
        break
'
}

prism_create_image() {
  local name="$1" uri="$2" body
  body="$(NAME="${name}" URI="${uri}" python3 -c 'import json,os; print(json.dumps({"spec":{"name":os.environ["NAME"],"resources":{"image_type":"DISK_IMAGE","source_uri":os.environ["URI"]}},"metadata":{"kind":"image"}}))')"
  prism_curl -X POST -H 'Content-Type: application/json' "$(prism_base)/images" -d "${body}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["uuid"])'
}

prism_image_state() {
  local uuid="$1"
  prism_curl "$(prism_base)/images/${uuid}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("state",""))'
}

prism_wait_image() {
  local uuid="$1" state i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    state="$(prism_image_state "${uuid}")"
    case "${state}" in
      COMPLETE) return 0 ;;
      ERROR)
        printf 'Prism image %s entered ERROR\n' "${uuid}" >&2
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
  if [[ -z "${IMAGE_SOURCE_URI:-}" ]]; then
    printf 'no Prism image %s and IMAGE_SOURCE_URI is unset\n' "${name}" >&2
    return 1
  fi
  uuid="$(prism_create_image "${name}" "${IMAGE_SOURCE_URI}")"
  [[ -n "${uuid}" ]] || return 1
  prism_wait_image "${uuid}"
}

prism_delete_image() {
  local name="$1" found uuid
  found="$(prism_find_image "${name}" || true)"
  uuid="${found%%$'\t'*}"
  [[ -n "${uuid}" ]] || return 0
  prism_curl -X DELETE "$(prism_base)/images/${uuid}" || {
    printf 'Prism image %s (%s) was already gone or delete failed\n' "${name}" "${uuid}" >&2
    return 0
  }
}
