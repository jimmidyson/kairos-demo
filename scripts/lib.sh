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

# Distro image whose glibc matches a Kairos base. The cri sysext links against
# this, not the Kairos image (kairos-init is a poor build root).
distro_image() {
  local os="$1"
  case "${os}" in
    ubuntu-*) printf 'ubuntu:%s\n' "${os#ubuntu-}" ;;
    rocky-9) printf '%s\n' "${ROCKY_BASE_IMAGE:-rockylinux:9}" ;;
    rhel-*)
      if [[ -z "${BASE_IMAGE:-}" ]]; then
        printf 'BASE_IMAGE is required for %s\n' "${os}" >&2
        return 1
      fi
      printf '%s\n' "${BASE_IMAGE}"
      ;;
    *)
      printf 'unsupported OS %s\n' "${os}" >&2
      return 1
      ;;
  esac
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

apple_container_available() {
  [[ "$(uname -s)" == Darwin ]] || return 1
  command -v container >/dev/null 2>&1
}

apple_k8s_available() {
  apple_container_available || return 1
  container --help 2>/dev/null | grep -q 'k8s'
}

# auto|docker|container. Explicit values are not checked against the host.
builder_name() {
  case "${KAIROS_BUILDER:-auto}" in
    docker | container) printf '%s\n' "${KAIROS_BUILDER}" ;;
    auto)
      if apple_container_available; then
        printf 'container\n'
      else
        printf 'docker\n'
      fi
      ;;
    *)
      printf 'KAIROS_BUILDER=%s is not auto, docker, or container\n' "${KAIROS_BUILDER}" >&2
      return 2
      ;;
  esac
}

# auto|kind|container. The cluster name stays KAIROS_KIND_CLUSTER_NAME.
mgmt_name() {
  case "${KAIROS_MGMT:-auto}" in
    kind | container) printf '%s\n' "${KAIROS_MGMT}" ;;
    auto)
      if apple_k8s_available; then
        printf 'container\n'
      else
        printf 'kind\n'
      fi
      ;;
    *)
      printf 'KAIROS_MGMT=%s is not auto, kind, or container\n' "${KAIROS_MGMT}" >&2
      return 2
      ;;
  esac
}

# Crane and AuroraBoot's registry client read this file. Writing it is not a docker CLI call.
write_registry_config() {
  local dir="$1"
  mkdir -p "${dir}"
  OCI_REGISTRY="${OCI_REGISTRY}" OCI_REGISTRY_USERNAME="${OCI_REGISTRY_USERNAME}" \
    OCI_REGISTRY_PASSWORD="${OCI_REGISTRY_PASSWORD}" python3 - "${dir}/config.json" <<'PY'
import base64, json, os, sys
reg = os.environ["OCI_REGISTRY"]
user = os.environ["OCI_REGISTRY_USERNAME"]
pw = os.environ["OCI_REGISTRY_PASSWORD"]
auth = base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()
with open(sys.argv[1], "w") as f:
    json.dump({"auths": {reg: {"auth": auth}}}, f)
PY
  chmod 644 "${dir}/config.json"
}

prepare_registry_auth() {
  [[ -n "${_registry_auth_ready:-}" ]] && return 0
  require_env OCI_REGISTRY
  require_env OCI_REGISTRY_USERNAME
  require_env OCI_REGISTRY_PASSWORD
  local dir="${FACTORY_ROOT}/build/registry-config"
  write_registry_config "${dir}"
  export DOCKER_CONFIG="${dir}"
  if [[ "$(builder_name)" == container ]]; then
    printf '%s\n' "${OCI_REGISTRY_PASSWORD}" | container registry login \
      --username "${OCI_REGISTRY_USERNAME}" --password-stdin "${OCI_REGISTRY}"
  fi
  _registry_auth_ready=1
}

harbor_login() {
  prepare_registry_auth
}

# True when the tag is already in the registry. A miss, including a registry
# error, is false so the caller builds. Delete the tag to force a rebuild.
registry_image_exists() {
  local ref="$1"
  prepare_registry_auth
  crane digest "${ref}" >/dev/null 2>&1
}

# Not a known minimum. Docker 24.0.6 / BuildKit v0.11.6 commits a large
# RUN --mount as whiteouts of /, so the next step has no /bin/sh.
# Docker 29.8.1 / BuildKit v0.33.0 does not. Versions in between were not
# tested. KAIROS_SKIP_DOCKER_CHECK=1 skips the check.
MIN_DOCKER_VERSION=29.8.1
MIN_BUILDKIT_VERSION=0.33.0

# version_at_least HAVE NEED. Compares the first three numeric components.
version_at_least() {
  local have="$1" need="$2" IFS=. i h n
  local -a hv nv
  have="${have#v}"
  need="${need#v}"
  have="${have%%+*}"
  need="${need%%+*}"
  have="${have%%-*}"
  need="${need%%-*}"
  # shellcheck disable=SC2162
  read -r -a hv <<<"${have}"
  # shellcheck disable=SC2162
  read -r -a nv <<<"${need}"
  for i in 0 1 2; do
    h="${hv[i]:-0}"
    n="${nv[i]:-0}"
    h="${h%%[!0-9]*}"
    n="${n%%[!0-9]*}"
    [[ -n "${h}" ]] || h=0
    [[ -n "${n}" ]] || n=0
    if ((10#$h > 10#$n)); then
      return 0
    fi
    if ((10#$h < 10#$n)); then
      return 1
    fi
  done
  return 0
}

require_docker_buildkit() {
  [[ -n "${_docker_buildkit_ok:-}" ]] && return 0
  if [[ "${KAIROS_SKIP_DOCKER_CHECK:-}" == 1 ]]; then
    printf 'skipping Docker/BuildKit version check (KAIROS_SKIP_DOCKER_CHECK=1). Known bad: Docker 24.0.6 / BuildKit v0.11.6. Known good: %s / v%s. The minimum in between is unknown.\n' \
      "${MIN_DOCKER_VERSION}" "${MIN_BUILDKIT_VERSION}" >&2
    _docker_buildkit_ok=1
    return 0
  fi
  local docker_ver buildkit_ver
  docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || {
    printf 'docker version failed. Known good is Docker %s / BuildKit v%s; the real minimum is unknown. Set KAIROS_SKIP_DOCKER_CHECK=1 to build anyway.\n' \
      "${MIN_DOCKER_VERSION}" "${MIN_BUILDKIT_VERSION}" >&2
    return 2
  }
  buildkit_ver="$(docker buildx inspect 2>/dev/null | awk '/BuildKit version:/ {print $3; exit}')"
  if [[ -z "${buildkit_ver}" ]]; then
    printf 'could not read BuildKit version from docker buildx inspect. Known good is v%s; the real minimum is unknown. Set KAIROS_SKIP_DOCKER_CHECK=1 to build anyway.\n' \
      "${MIN_BUILDKIT_VERSION}" >&2
    return 2
  fi
  if ! version_at_least "${docker_ver}" "${MIN_DOCKER_VERSION}" \
    || ! version_at_least "${buildkit_ver}" "${MIN_BUILDKIT_VERSION}"; then
    printf 'docker %s / BuildKit %s is below the only pair known to work (Docker %s / BuildKit v%s). Docker 24.0.6 / BuildKit v0.11.6 whiteouts a large RUN --mount. The minimum in between is unknown. Set KAIROS_SKIP_DOCKER_CHECK=1 to build anyway.\n' \
      "${docker_ver}" "${buildkit_ver}" "${MIN_DOCKER_VERSION}" "${MIN_BUILDKIT_VERSION}" >&2
    return 2
  fi
  _docker_buildkit_ok=1
}

# Image build. --push uses buildx on Docker and `container image push` on Apple container.
# A local build (no --push) is loaded into the engine `kind load` or `container k8s load-image` reads.
# ponytail: Apple container rejects Dockerfiles over 16KiB (container#735). These Dockerfiles are smaller.
oci_build() {
  local builder="" platform="" file="" tag="" push=0 context=""
  local build_args=() secrets=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --builder) builder="${2:-}"; shift 2 ;;
      --builder=*) builder="${1#--builder=}"; shift ;;
      --platform) platform="${2:-}"; shift 2 ;;
      --platform=*) platform="${1#--platform=}"; shift ;;
      --file | -f) file="${2:-}"; shift 2 ;;
      --file=* | -f=*) file="${1#*=}"; shift ;;
      --tag | -t) tag="${2:-}"; shift 2 ;;
      --tag=* | -t=*) tag="${1#*=}"; shift ;;
      --build-arg) build_args+=("${2:-}"); shift 2 ;;
      --build-arg=*) build_args+=("${1#--build-arg=}"); shift ;;
      --secret) secrets+=("${2:-}"); shift 2 ;;
      --secret=*) secrets+=("${1#--secret=}"); shift ;;
      --push) push=1; shift ;;
      --) shift; break ;;
      -*)
        printf 'oci_build: unknown flag %s\n' "$1" >&2
        return 2
        ;;
      *) context="$1"; shift ;;
    esac
  done
  if [[ -z "${tag}" || -z "${context}" ]]; then
    printf 'oci_build: need a tag and a context directory\n' >&2
    return 2
  fi
  if [[ -z "${builder}" ]]; then
    builder="$(builder_name)"
  fi
  if [[ "${builder}" == docker ]]; then
    require_docker_buildkit
  fi
  printf '  build via %s %s\n' "${builder}" "${tag}" >&2
  local cmd=() a
  case "${builder}" in
    container)
      cmd=(container build --tag "${tag}")
      ;;
    docker)
      if [[ "${push}" -eq 1 || ${#secrets[@]} -gt 0 ]]; then
        cmd=(docker buildx build)
        if [[ "${push}" -eq 1 ]]; then
          cmd+=(--push)
        else
          cmd+=(--load)
        fi
      else
        cmd=(docker build)
      fi
      cmd+=(--tag "${tag}")
      ;;
    *)
      printf 'oci_build: unknown builder %s\n' "${builder}" >&2
      return 2
      ;;
  esac
  [[ -n "${file}" ]] && cmd+=(--file "${file}")
  [[ -n "${platform}" ]] && cmd+=(--platform "${platform}")
  if [[ ${#build_args[@]} -gt 0 ]]; then
    for a in "${build_args[@]}"; do
      cmd+=(--build-arg "${a}")
    done
  fi
  if [[ ${#secrets[@]} -gt 0 ]]; then
    for a in "${secrets[@]}"; do
      cmd+=(--secret "${a}")
    done
  fi
  cmd+=("${context}")
  "${cmd[@]}"
  if [[ "${builder}" == container && "${push}" -eq 1 ]]; then
    prepare_registry_auth
    container image push "${tag}"
  fi
}

# The rootfs is already in the registry. AuroraBoot pulls it. Neither runner
# gets a Docker socket: that socket is root on the host.
run_auroraboot_sysext() {
  local name="$1" image="$2" arch="$3" out_dir="$4" rc=0
  mkdir -p "${out_dir}"
  prepare_registry_auth
  case "$(builder_name)" in
    container)
      container run --rm \
        -e DOCKER_CONFIG=/auth \
        --mount "type=bind,source=${out_dir},target=/build" \
        --mount "type=bind,source=${DOCKER_CONFIG},target=/auth,readonly" \
        "${AURORABOOT_IMAGE}" \
        sysext --arch "${arch}" --output=/build "${name}" "${image}" || rc=$?
      ;;
    *)
      docker run --rm \
        -e DOCKER_CONFIG=/auth \
        -v "${out_dir}:/build" \
        -v "${DOCKER_CONFIG}:/auth:ro" \
        "${AURORABOOT_IMAGE}" \
        sysext --arch "${arch}" --output=/build "${name}" "${image}" || rc=$?
      ;;
  esac
  return "${rc}"
}

mgmt_exists() {
  local name="$1"
  case "$(mgmt_name)" in
    kind) kind get clusters 2>/dev/null | grep -qx "${name}" ;;
    container) container k8s list | awk -v n="${name}" 'NR>1 && $1==n { found=1 } END { exit !found }' ;;
  esac
}

mgmt_create() {
  local name="$1"
  case "$(mgmt_name)" in
    kind) kind create cluster --name "${name}" ;;
    container) container k8s create --name "${name}" ;;
  esac
}

mgmt_delete() {
  local name="$1"
  case "$(mgmt_name)" in
    kind) kind delete cluster --name "${name}" ;;
    container) container k8s delete --name "${name}" ;;
  esac
}

mgmt_write_kubeconfig() {
  local name="$1" dest="$2"
  case "$(mgmt_name)" in
    kind) kind get kubeconfig --name "${name}" >"${dest}" ;;
    container)
      rm -f "${dest}"
      container k8s write-config --name "${name}" --kubeconfig "${dest}"
      ;;
  esac
}

# Build the extension into the image store the management cluster can load.
mgmt_build_and_load() {
  local image="$1" file="$2" context="$3"
  shift 3
  case "$(mgmt_name)" in
    container)
      oci_build --builder container "$@" --tag "${image}" --file "${file}" "${context}"
      container k8s load-image --name "${KAIROS_KIND_CLUSTER_NAME}" "${image}"
      ;;
    *)
      oci_build --builder docker "$@" --tag "${image}" --file "${file}" "${context}"
      kind load docker-image "${image}" --name "${KAIROS_KIND_CLUSTER_NAME}"
      ;;
  esac
}
