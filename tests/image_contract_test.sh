#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -q 'kubeadm init' "${ROOT}/image/cloud-config.yaml" && fail "OEM cloud-config must not kubeadm init"
grep -q 'prepare-capi-node' "${ROOT}/image/cloud-config.yaml" && fail "OEM must not call prepare-capi-node; CAPI preKubeadmCommands owns that"
grep -q 'nkpadmin' "${ROOT}/image/cloud-config.yaml" || fail "missing debug user"
# shellcheck source=../versions.env
source "${ROOT}/versions.env"
case "${KAIROS_IMAGE_VERSION}" in
  v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "KAIROS_IMAGE_VERSION=${KAIROS_IMAGE_VERSION} is not semver" ;;
esac
grep -q 'git describe' "${ROOT}/scripts/02-build-bases.sh" && fail "02-build-bases must not feed git describe to kairos-init"
for f in image/harden-ubuntu.sh image/harden-el.sh; do
  [[ -f "${ROOT}/${f}" ]] || fail "missing ${f}"
done
grep -q 'pro enable usg' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: enable usg (not only fips)"
grep -q 'cis_level1_server' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: CIS L1"
grep -q 'disa_stig' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: STIG"
grep -q 'fips' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: FIPS"
# The old `pro enable fips || pro enable usg` skips USG when FIPS works.
grep -E 'pro enable fips.*\|\|.*pro enable usg' "${ROOT}/image/harden-ubuntu.sh" && fail "ubuntu: FIPS must not skip USG"
grep -q 'fips-mode-setup' "${ROOT}/image/harden-el.sh" || fail "el: FIPS"
grep -q 'cis_server_l1' "${ROOT}/image/harden-el.sh" || fail "el: CIS L1"
grep -q 'profile_stig\|/stig' "${ROOT}/image/harden-el.sh" || fail "el: STIG"
grep -q 'ssg-rl9-ds.xml' "${ROOT}/image/harden-el.sh" || fail "el: Rocky datastream"
grep -q 'ssg-rhel9-ds.xml' "${ROOT}/image/harden-el.sh" || fail "el: RHEL datastream if BASE_IMAGE is RHEL"
echo "ok image_contract_test"
