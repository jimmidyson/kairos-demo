#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -q 'kubeadm init' "${ROOT}/image/cloud-config.yaml" && fail "OEM cloud-config must not kubeadm init"
grep -q 'prepare-capi-node' "${ROOT}/image/cloud-config.yaml" && fail "OEM must not call prepare-capi-node; CAPI preKubeadmCommands owns that"
grep -q 'nkpadmin' "${ROOT}/image/cloud-config.yaml" || fail "missing debug user"
echo "ok image_contract_test"
