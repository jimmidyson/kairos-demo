#!/usr/bin/env bash
# Source this, then call enable_fips_go.
# Exports GOFIPS140=certified and GOTOOLCHAIN=go${GO_VERSION}.
# etcd and Kubernetes download the Go in .go-version when GOTOOLCHAIN is
# unset. Set it first so every build uses the factory pin.

enable_fips_go() {
  : "${GO_VERSION:?GO_VERSION must be set}"
  export GOFIPS140=certified GO_VERSION
  export GOTOOLCHAIN="go${GO_VERSION}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  enable_fips_go
  printf 'export GOFIPS140=%q\n' "${GOFIPS140}"
  printf 'export GO_VERSION=%q\n' "${GO_VERSION}"
  printf 'export GOTOOLCHAIN=%q\n' "${GOTOOLCHAIN}"
fi
