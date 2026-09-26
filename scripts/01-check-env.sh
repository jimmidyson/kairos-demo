#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

step_start 1 "Check environment and registry login" \
  "Fail fast on missing secrets; prove we can push to Harbor." \
  "registry login ${OCI_REGISTRY:-<OCI_REGISTRY>}"

require_factory_env
if [[ "$(builder_name)" == docker ]]; then
  require_docker_buildkit
fi
harbor_login
step_ok
next_step 2
