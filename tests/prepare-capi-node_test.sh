#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../image/prepare-capi-node
source "${ROOT}/image/prepare-capi-node"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(detect_os $'ID=ubuntu\nVERSION_ID=\"24.04\"')" == "ubuntu-24.04" ]] || fail "ubuntu 24.04"
[[ "$(detect_os $'ID=ubuntu\nVERSION_ID=\"22.04\"')" == "ubuntu-22.04" ]] || fail "ubuntu 22.04"
[[ "$(detect_os $'ID=\"rocky\"\nVERSION_ID=\"9.5\"')" == "rocky-9" ]] || fail "rocky 9"
[[ "$(detect_arch x86_64)" == "amd64" ]] || fail "amd64"
[[ "$(detect_arch aarch64)" == "arm64" ]] || fail "arm64"

reg="harbor.example.com/kairos-demo"
[[ "$(containerd_ref "${reg}" ubuntu-24.04 amd64 2.4.0)" == "${reg}/containerd:2.4.0-ubuntu-24.04-amd64" ]] || fail "containerd_ref"
[[ "$(kubernetes_ref "${reg}" v1.36.4 arm64)" == "${reg}/kubernetes:v1.36.4-arm64" ]] || fail "k8s_ref"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
export PREPARE_CAPI_NODE_ROOT="${tmpdir}"
mkdir -p "${tmpdir}/var/lib/kairos/extensions"

if prepare-capi-node-main 2>/tmp/pcn-err; then
  fail "should require --registry"
fi
grep -q -- '--registry' /tmp/pcn-err || fail "missing --registry message: $(cat /tmp/pcn-err)"

prepare-capi-node-main --registry "${reg}" --kubernetes-version v1.36.4 --os ubuntu-24.04 --arch amd64
[[ -f "${tmpdir}/var/lib/kairos/extensions/capi-node.set" ]] || fail "set file not written"
already_applied "${tmpdir}/var/lib/kairos/extensions/capi-node.set" "${reg}" ubuntu-24.04 amd64 v1.36.4 || fail "should be applied"
[[ -f "${tmpdir}/var/lib/kairos/extensions/containerd-2.4.0-ubuntu-24.04-amd64.sysext.raw" ]] || fail "versioned containerd extension not written"
[[ -f "${tmpdir}/var/lib/kairos/extensions/kubernetes-v1.36.4-amd64.sysext.raw" ]] || fail "versioned kubernetes extension not written"
# Forwarding is configured in the OS image, not by prepare-capi-node.
[[ ! -e "${tmpdir}/etc/sysctl.d/99-kubernetes-cri.conf" ]] || fail "prepare-capi-node must not configure forwarding"
[[ ! -e "${tmpdir}/proc/sys/net/ipv4/ip_forward" ]] || fail "prepare-capi-node must not configure live forwarding"

# no-op: second run must not rewrite the active versioned extension if we stamp a marker
echo marker > "${tmpdir}/var/lib/kairos/extensions/kubernetes-v1.36.4-amd64.sysext.raw"
prepare-capi-node-main --registry "${reg}" --kubernetes-version v1.36.4 --os ubuntu-24.04 --arch amd64
[[ "$(cat "${tmpdir}/var/lib/kairos/extensions/kubernetes-v1.36.4-amd64.sysext.raw")" == "marker" ]] || fail "no-op bounced files"

[[ "$(detect_os $'ID=rhel\nVERSION_ID=\"9.4\"')" == "rhel-9" ]] || fail "rhel 9"

grep -q '^version = 4$' "${tmpdir}/etc/containerd/conf.d/capi-sandbox.toml" || fail "containerd sandbox drop-in version"
grep -q "io.containerd.cri.v1.images" "${tmpdir}/etc/containerd/conf.d/capi-sandbox.toml" || fail "containerd 2 sandbox key"
grep -q 'sandbox = "' "${tmpdir}/etc/containerd/conf.d/capi-sandbox.toml" || fail "sandbox pin"
grep -q '^version = 4$' "${tmpdir}/etc/containerd/conf.d/cgroup.toml" || fail "containerd cgroup drop-in version"
grep -q "io.containerd.cri.v1.runtime" "${tmpdir}/etc/containerd/conf.d/cgroup.toml" || fail "containerd 2 cgroup key"
grep -q 'SystemdCgroup = true' "${tmpdir}/etc/containerd/conf.d/cgroup.toml" || fail "containerd systemd cgroup"
[[ ! -e "${tmpdir}/etc/containerd/config.toml" ]] || fail "prepare-capi-node must not create containerd config"
grep -q 'containerd_cgroup=systemd' "${tmpdir}/var/lib/kairos/extensions/capi-node.set" || fail "systemd cgroup state"

log="${tmpdir}/actions.log"
: >"${log}"
export PREPARE_CAPI_NODE_LOG="${log}"
prepare-capi-node-main --registry "${reg}" --kubernetes-version v1.36.5 --os ubuntu-24.04 --arch amd64
pull_line="$(grep -n '^pull ' "${log}" | head -1 | cut -d: -f1)"
stop_line="$(grep -n '^stop kubelet$' "${log}" | head -1 | cut -d: -f1)"
[[ -n "${pull_line}" && -n "${stop_line}" && "${pull_line}" -lt "${stop_line}" ]] || fail "pull must happen before stop: $(cat "${log}")"

prepare-capi-node-main --registry "other.example/p" --kubernetes-version v1.36.5 --os ubuntu-24.04 --arch amd64
grep -q 'other.example/p/containerd:2.4.0-ubuntu-24.04-amd64' "${tmpdir}/var/lib/kairos/extensions/containerd-2.4.0-ubuntu-24.04-amd64.sysext.raw" || fail "registry change did not refresh containerd"

mkdir -p "${tmpdir}/usr/lib/kairos"
printf '3.10.1\n' >"${tmpdir}/usr/lib/kairos/pause-tag"
prepare-capi-node-main --registry "${reg}" --kubernetes-version v1.36.6 --os ubuntu-24.04 --arch amd64
grep -q 'pause:3.10.1' "${tmpdir}/etc/containerd/conf.d/capi-sandbox.toml" || fail "pause tag from sysext file"

echo "ok prepare-capi-node_test"
