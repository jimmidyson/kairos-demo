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
# archive.ubuntu.com occasionally publishes Release before Packages.gz. Retry the mismatch.
n=0
until apt-get update; do
  n=$((n + 1))
  [[ "${n}" -lt 5 ]] || exit 1
  echo "apt-get update failed (attempt ${n}); retrying after mirror sync" >&2
  rm -rf /var/lib/apt/lists/*
  sleep $((n * 5))
done
apt-get install -y --no-install-recommends usg ca-certificates curl

usg fix cis_level1_server
if usg fix disa_stig; then
  echo "applied disa_stig"
else
  echo "STIG profile not available on this Ubuntu/USG release; CIS + FIPS still applied"
fi

mkdir -p /etc/default
touch /etc/default/grub
grep -q 'fips=1' /etc/default/grub || printf '\nGRUB_CMDLINE_LINUX="fips=1 ${GRUB_CMDLINE_LINUX:-}"\n' >>/etc/default/grub

# The Pro token must not ship in the image. FIPS packages stay installed.
rm -rf /var/lib/ubuntu-advantage/private
rm -f /var/log/ubuntu-advantage.log /var/log/ubuntu-advantage-timer.log /var/log/ubuntu-advantage-apt-hook.log
if [[ -f /etc/ubuntu-advantage/uaclient.conf ]]; then
  sed -i '/token/d' /etc/ubuntu-advantage/uaclient.conf || true
fi
