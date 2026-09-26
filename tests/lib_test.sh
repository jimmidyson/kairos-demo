#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

version_at_least 29.8.1 29.8.1 || fail "equal docker version"
version_at_least 29.9.0 29.8.1 || fail "newer docker version"
version_at_least v0.33.0 0.33.0 || fail "equal buildkit version"
version_at_least v0.34.0 0.33.0 || fail "newer buildkit version"
if version_at_least 24.0.6 29.8.1; then fail "docker 24 must be rejected"; fi
if version_at_least v0.11.6 0.33.0; then fail "buildkit 0.11 must be rejected"; fi
if version_at_least 29.8.0 29.8.1; then fail "docker 29.8.0 must be rejected"; fi

out="$(require_env NOT_A_REAL_ENV 2>&1)" && fail "require_env should fail" || true
[[ "${out}" == *"missing env: NOT_A_REAL_ENV"* ]] || fail "got: ${out}"

export OCI_REGISTRY=harbor.example.com
export OCI_REPOSITORY_PREFIX=kairos-demo
[[ "$(image_prefix)" == "harbor.example.com/kairos-demo" ]] || fail "image_prefix"

[[ "$(base_image ubuntu-24.04 amd64)" == "harbor.example.com/kairos-demo/base:ubuntu-24.04-amd64" ]] || fail "base_image"
[[ "$(cri_image rocky-9 arm64)" == "harbor.example.com/kairos-demo/cri:rocky-9-arm64" ]] || fail "cri_image"
[[ "$(kubernetes_image v1.36.4 amd64)" == "harbor.example.com/kairos-demo/kubernetes:v1.36.4-amd64" ]] || fail "kubernetes_image"
[[ "$(distro_image ubuntu-24.04)" == "ubuntu:24.04" ]] || fail "distro ubuntu"
[[ "$(distro_image rocky-9)" == "rockylinux:9" ]] || fail "distro rocky"

next_out="$(next_step 2 2>&1)" || fail "next_step failed: ${next_out}"
[[ "${next_out}" == *"02-build-bases.sh"* ]] || fail "next_step path: ${next_out}"
[[ "${next_out}" != *"compgen"* ]] || fail "next_step used compgen: ${next_out}"

# %s must print real ESC, not the two-char sequence \033
_c_blue=$'\033[34;1m'
_c_reset=$'\033[0m'
colored="$(printf '%s▶%s' "${_c_blue}" "${_c_reset}")"
[[ "${colored}" == $'\033[34;1m▶\033[0m' ]] || fail "color codes not ESC"

export KAIROS_BUILDER=docker
[[ "$(builder_name)" == docker ]] || fail "builder docker"
export KAIROS_BUILDER=container
[[ "$(builder_name)" == container ]] || fail "builder container"
export KAIROS_MGMT=kind
[[ "$(mgmt_name)" == kind ]] || fail "mgmt kind"
export KAIROS_MGMT=container
[[ "$(mgmt_name)" == container ]] || fail "mgmt container"
export KAIROS_BUILDER=nope
builder_name >/dev/null 2>&1 && fail "bad builder should fail"
export KAIROS_BUILDER=auto
export KAIROS_MGMT=auto

shim="$(mktemp -d)"
log="${shim}/log"
cat >"${shim}/container" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${LOG}"
EOF
cat >"${shim}/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${LOG}"
case "$1" in
  version) printf '%s\n' "${DOCKER_SERVER_VERSION:-29.8.1}" ;;
  buildx) printf 'BuildKit version: %s\n' "${BUILDKIT_VERSION:-v0.33.0}" ;;
esac
EOF
chmod +x "${shim}/container" "${shim}/docker"
ctx="$(mktemp -d)"
export OCI_REGISTRY=example.com OCI_REGISTRY_USERNAME=u OCI_REGISTRY_PASSWORD=p
LOG="${log}" PATH="${shim}:${PATH}" oci_build --builder container --push \
  --platform=linux/amd64 --build-arg=FOO=bar --secret=id=t,env=PATH \
  --file="${ctx}/Dockerfile" --tag=example.com/a:1 "${ctx}"
grep -qx 'build --tag example.com/a:1 --file '"${ctx}"'/Dockerfile --platform linux/amd64 --build-arg FOO=bar --secret id=t,env=PATH '"${ctx}" "${log}" \
  || fail "container build args: $(cat "${log}")"
grep -qx 'image push example.com/a:1' "${log}" || fail "container push: $(cat "${log}")"
: >"${log}"
LOG="${log}" PATH="${shim}:${PATH}" oci_build --builder docker --tag=example.com/a:1 "${ctx}"
grep -qx 'build --tag example.com/a:1 '"${ctx}" "${log}" || fail "docker build args: $(cat "${log}")"
unset _docker_buildkit_ok
if LOG="${log}" PATH="${shim}:${PATH}" DOCKER_SERVER_VERSION=24.0.6 BUILDKIT_VERSION=v0.11.6 \
  require_docker_buildkit; then
  fail "docker 24 / buildkit 0.11 must be rejected"
fi
unset _docker_buildkit_ok
if ! LOG="${log}" PATH="${shim}:${PATH}" KAIROS_SKIP_DOCKER_CHECK=1 \
  DOCKER_SERVER_VERSION=24.0.6 BUILDKIT_VERSION=v0.11.6 \
  require_docker_buildkit; then
  fail "KAIROS_SKIP_DOCKER_CHECK=1 should allow an old engine"
fi
unset _docker_buildkit_ok KAIROS_SKIP_DOCKER_CHECK
cat >"${shim}/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${LOG}"
if [[ "$1" == buildx ]]; then
  echo "buildx exploded" >&2
  exit 255
fi
printf '%s\n' "29.8.1"
EOF
chmod +x "${shim}/docker"
: >"${log}"
if LOG="${log}" PATH="${shim}:${PATH}" require_docker_buildkit >"${log}.out" 2>"${log}.err"; then
  fail "buildx inspect exit 255 must fail the check"
fi
grep -q 'buildx exploded' "${log}.err" || fail "inspect failure must be shown: $(cat "${log}.err")"
unset _docker_buildkit_ok
cat >"${shim}/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${LOG}"
case "$1" in
  version) printf '%s\n' "${DOCKER_SERVER_VERSION:-29.8.1}" ;;
  buildx) printf 'BuildKit version: %s\n' "${BUILDKIT_VERSION:-v0.33.0}" ;;
esac
EOF
chmod +x "${shim}/docker"
: >"${log}"
LOG="${log}" PATH="${shim}:${PATH}" KAIROS_BUILDER=docker \
  OCI_REGISTRY=example.com OCI_REGISTRY_USERNAME=u OCI_REGISTRY_PASSWORD=p \
  run_auroraboot_sysext cri example.com/root:1 amd64 "${ctx}"
grep -q 'sysext --arch amd64' "${log}" || fail "sysext arch: $(cat "${log}")"
grep -q 'docker.sock' "${log}" && fail "docker auroraboot must not mount the socket: $(cat "${log}")"
grep -q 'DOCKER_CONFIG=/auth' "${log}" || fail "docker auroraboot registry config: $(cat "${log}")"
unset _registry_auth_ready DOCKER_CONFIG
: >"${log}"
LOG="${log}" PATH="${shim}:${PATH}" KAIROS_BUILDER=container \
  OCI_REGISTRY=example.com OCI_REGISTRY_USERNAME=u OCI_REGISTRY_PASSWORD=p \
  run_auroraboot_sysext cri example.com/root:1 arm64 "${ctx}"
grep -q 'run --rm' "${log}" || fail "container run auroraboot: $(cat "${log}")"
grep -q 'sysext --arch arm64' "${log}" || fail "container sysext args: $(cat "${log}")"
grep -q 'docker.sock' "${log}" && fail "apple container auroraboot must not use the docker socket: $(cat "${log}")"
grep -q 'load -i' "${log}" && fail "apple container auroraboot must not docker load: $(cat "${log}")"
cat >"${shim}/crane" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${LOG}"
[[ "${CRANE_EXISTS:-}" == 1 ]]
EOF
chmod +x "${shim}/crane"
unset _registry_auth_ready
: >"${log}"
if ! LOG="${log}" PATH="${shim}:${PATH}" KAIROS_BUILDER=docker CRANE_EXISTS=1 \
  registry_image_exists example.com/root:1; then
  fail "existing tag should skip the build"
fi
grep -q '^digest example.com/root:1$' "${log}" || fail "crane digest: $(cat "${log}")"
if LOG="${log}" PATH="${shim}:${PATH}" KAIROS_BUILDER=docker CRANE_EXISTS=0 \
  registry_image_exists example.com/missing:1; then
  fail "missing tag should rebuild"
fi
rm -rf "${shim}" "${ctx}" "${FACTORY_ROOT}/build/registry-config"
unset DOCKER_CONFIG _registry_auth_ready OCI_REGISTRY OCI_REGISTRY_USERNAME OCI_REGISTRY_PASSWORD

echo "ok lib_test"
