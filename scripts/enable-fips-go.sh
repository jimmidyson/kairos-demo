#!/usr/bin/env bash
# Source this, then call enable_fips_go <version-or-file>.
# Exports GOFIPS140=certified. When the declared Go is older than the
# release that added the certified alias, also exports GOTOOLCHAIN.

enable_fips_go() {
  local spec="${1:-}" v="" patch
  if [[ -f "${spec}" ]]; then
    v="$(tr -d '[:space:]' <"${spec}")"
  else
    v="${spec}"
  fi
  export GOFIPS140=certified
  unset GOTOOLCHAIN
  case "${v}" in
    1.25.*)
      patch="${v#1.25.}"
      patch="${patch%%[!0-9]*}"
      if [[ -n "${patch}" && "${patch}" -lt 10 ]]; then
        export GOTOOLCHAIN=go1.25.10
      fi
      ;;
    1.26.*)
      patch="${v#1.26.}"
      patch="${patch%%[!0-9]*}"
      if [[ -n "${patch}" && "${patch}" -lt 3 ]]; then
        export GOTOOLCHAIN=go1.26.3
      fi
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  enable_fips_go "${1:-}"
  printf 'export GOFIPS140=%q\n' "${GOFIPS140}"
  if [[ -n "${GOTOOLCHAIN:-}" ]]; then
    printf 'export GOTOOLCHAIN=%q\n' "${GOTOOLCHAIN}"
  fi
fi
