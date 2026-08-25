#!/usr/bin/env bash
# RHEL-family (Rocky 9, RHEL 9): FIPS via fips-mode-setup; CIS L1 + STIG via OpenSCAP.
# No Ubuntu Pro. Datastream is distro-specific. oscap --remediate exits non-zero when
# rules cannot apply in a container/image build — that is expected, not fatal.
set -euo pipefail

dnf -y install crypto-policies-scripts openscap-scanner scap-security-guide \
  ca-certificates curl tar gzip
fips-mode-setup --enable

ds=""
for f in \
  /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml \
  /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml \
  /usr/share/xml/scap/ssg/content/ssg-cs9-ds.xml
do
  if [[ -f "${f}" ]]; then
    ds="${f}"
    break
  fi
done

if [[ -z "${ds}" ]]; then
  echo "no SCAP datastream; CIS/STIG skipped (FIPS still enabled)" >&2
  dnf clean all
  exit 0
fi

echo "using SCAP datastream ${ds}"
# CIS L1 then STIG. STIG last on conflicts. Many rules need a real boot/grub.
oscap xccdf eval --remediate --profile xccdf_org.ssgproject.content_profile_cis_server_l1 "${ds}" \
  || echo "CIS L1 remediate finished with findings (ok in image build)"
oscap xccdf eval --remediate --profile xccdf_org.ssgproject.content_profile_stig "${ds}" \
  || echo "STIG remediate finished with findings (ok in image build)"

dnf clean all
