#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

usage() {
  cat <<EOF
Kairos CAPI FIPS factory

  ./demo.sh           run steps 1–10
  ./demo.sh N         run only step N (1–10)
  ./demo.sh 1 2 3     run a subset in order

Each step prints what/why/touch, then the next command if you stop.
Spec: docs/superpowers/specs/2026-08-25-capi-kairos-fips-design.md
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# bash 3.2 (macOS /bin/bash) has no mapfile
ALL=()
for f in "${ROOT}"/scripts/[0-9][0-9]-*.sh; do
  [[ -f "${f}" ]] && ALL+=("${f}")
done

run_one() {
  local n="$1" f found=""
  local prefix="${ROOT}/scripts/$(printf '%02d' "${n}")-"
  for f in "${prefix}"*.sh; do
    [[ -f "${f}" ]] || continue
    found="${f}"
    break
  done
  if [[ -z "${found}" ]]; then
    echo "no step ${n}" >&2
    exit 2
  fi
  bash "${found}"
}

if [[ $# -eq 0 ]]; then
  for f in "${ALL[@]}"; do
    bash "${f}"
  done
  exit 0
fi

for n in "$@"; do
  run_one "${n}"
done
