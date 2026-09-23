#!/usr/bin/env bash
# Ubuntu Pro: FIPS + CIS L1 + DISA STIG (STIG last; skipped if USG has no profile).
# CIS and STIG overlap; later profile wins on conflicts. Not a certified assessment.
set -euo pipefail

token="${1:-/run/secrets/ubuntu-pro-token}"
if [[ ! -s "${token}" ]]; then
  echo "ubuntu pro token missing at ${token}" >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
pro attach "$(cat "${token}")"
pro enable usg --assume-yes
# FIPS is separate from USG. Do not `fips || usg` — that skips USG when FIPS works.
if ! pro enable fips-updates --assume-yes; then
  pro enable fips --assume-yes
fi
apt-get update
apt-get install -y --no-install-recommends usg ca-certificates curl

usg fix cis_level1_server
if usg fix disa_stig; then
  echo "applied disa_stig"
else
  echo "STIG profile not available on this Ubuntu/USG release; CIS + FIPS still applied"
fi
