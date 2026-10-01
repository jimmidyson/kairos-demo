#!/usr/bin/env bash
# Render the Nutanix CCM HelmChartProxy.
# nutanix.github.io/helm-releases is the NCM product index, not this chart.
# The cloud-provider chart is published from nutanix-cloud-native/cloud-provider-nutanix.
# Override with NUTANIX_CCM_REPO / NUTANIX_CCM_CHART / NUTANIX_CCM_CHART_VERSION.
set -euo pipefail

: "${NUTANIX_ENDPOINT:?}"
: "${NUTANIX_USER:?}"
: "${NUTANIX_PASSWORD:?}"

# JSON string literal, so a password or PEM-adjacent quote survives YAML.
json_quote() {
  jq -ajnr --arg v "$1" '$v'
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

repo="${NUTANIX_CCM_REPO:-https://nutanix-cloud-native.github.io/cloud-provider-nutanix}"
chart="${NUTANIX_CCM_CHART:-nutanix-cloud-provider}"
version="${NUTANIX_CCM_CHART_VERSION:-}"
insecure=false
if [[ "${NUTANIX_INSECURE:-}" == "1" ]]; then
  insecure=true
fi
ca_pem=""
if [[ -n "${NUTANIX_CA_FILE:-}" ]]; then
  ca_pem="$(trim "$(cat "${NUTANIX_CA_FILE}")")"
  insecure=false
fi

version_line=""
if [[ -n "${version}" ]]; then
  version_line="  version: $(json_quote "${version}")"$'\n'
fi

# Parameter expansion happens once, so a password containing $() stays literal.
cat <<EOF
apiVersion: addons.cluster.x-k8s.io/v1alpha1
kind: HelmChartProxy
metadata:
  name: nutanix-ccm
spec:
  clusterSelector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: kairos-capi
  repoURL: $(json_quote "${repo}")
  chartName: $(json_quote "${chart}")
  releaseName: nutanix-ccm
  namespace: kube-system
${version_line}  valuesTemplate: |
    config:
      prismCentral:
        address: $(json_quote "${NUTANIX_ENDPOINT}")
        port: 9440
        username: $(json_quote "${NUTANIX_USER}")
        password: $(json_quote "${NUTANIX_PASSWORD}")
        insecure: ${insecure}
EOF
if [[ -n "${ca_pem}" ]]; then
  printf '%s\n' '        additionalTrustBundle: |'
  sed 's/^/          /' <<<"${ca_pem}"
fi
