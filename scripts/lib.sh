#!/usr/bin/env bash
# Shared helpers for factory scripts. Safe to source from tests.

if [[ -n "${_KAIROS_FACTORY_LIB:-}" ]]; then
  return 0
fi
_KAIROS_FACTORY_LIB=1

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${FACTORY_ROOT}/versions.env"

# $'...' so %s prints ESC, not the two-char sequence \033. macOS /bin/bash is 3.2.
if [[ -t 1 ]]; then
  _c_blue=$'\033[34;1m'
  _c_green=$'\033[32;1m'
  _c_red=$'\033[31;1m'
  _c_dim=$'\033[2m'
  _c_reset=$'\033[0m'
else
  _c_blue='' _c_green='' _c_red='' _c_dim='' _c_reset=''
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'missing env: %s\n' "${name}" >&2
    return 2
  fi
}

image_prefix() {
  printf '%s/%s\n' "${OCI_REGISTRY:?}" "${OCI_REPOSITORY_PREFIX:?}"
}

base_image() {
  local os="$1" arch="$2"
  printf '%s/base:%s-%s\n' "$(image_prefix)" "${os}" "${arch}"
}

cri_image() {
  local os="$1" arch="$2"
  printf '%s/cri:%s-%s\n' "$(image_prefix)" "${os}" "${arch}"
}

kubernetes_image() {
  local ver="$1" arch="$2"
  printf '%s/kubernetes:%s-%s\n' "$(image_prefix)" "${ver}" "${arch}"
}

step_start() {
  local num="$1" title="$2" why="$3" touch="$4"
  printf '\n%s▶ step %s: %s%s\n' "${_c_blue}" "${num}" "${title}" "${_c_reset}"
  printf '%s  why:%s %s\n' "${_c_dim}" "${_c_reset}" "${why}"
  printf '%s  touch:%s %s\n' "${_c_dim}" "${_c_reset}" "${touch}"
}

step_ok() {
  printf '%s✓ ok%s\n' "${_c_green}" "${_c_reset}"
}

step_fail() {
  printf '%s✗ fail:%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2
}

next_step() {
  local n="$1" path="" f
  local prefix
  prefix="${FACTORY_ROOT}/scripts/$(printf '%02d' "${n}")-"
  for f in "${prefix}"*.sh; do
    [[ -f "${f}" ]] || continue
    path="${f}"
    break
  done
  [[ -n "${path}" ]] || return 0
  printf '%s  next:%s %s\n' "${_c_dim}" "${_c_reset}" "${path}"
  printf '%s  or:%s ./demo.sh %s\n' "${_c_dim}" "${_c_reset}" "${n}"
}

require_factory_env() {
  local v
  for v in \
    OCI_REGISTRY OCI_REPOSITORY_PREFIX OCI_REGISTRY_USERNAME OCI_REGISTRY_PASSWORD \
    UBUNTU_PRO_TOKEN \
    NUTANIX_ENDPOINT NUTANIX_USER NUTANIX_PASSWORD \
    NUTANIX_PRISM_ELEMENT_CLUSTER_NAME NUTANIX_SUBNET_NAME \
    NUTANIX_SSH_AUTHORIZED_KEY CONTROL_PLANE_ENDPOINT_IP
  do
    require_env "${v}"
  done
}

harbor_login() {
  require_env OCI_REGISTRY
  require_env OCI_REGISTRY_USERNAME
  require_env OCI_REGISTRY_PASSWORD
  printf '%s\n' "${OCI_REGISTRY_PASSWORD}" | docker login "${OCI_REGISTRY}" -u "${OCI_REGISTRY_USERNAME}" --password-stdin
}
