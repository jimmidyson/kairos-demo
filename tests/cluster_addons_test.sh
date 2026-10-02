#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ ! -f "${ROOT}/capi/cilium.yaml" ]] || fail "custom Cilium HelmChartProxy must be gone"
[[ ! -f "${ROOT}/scripts/render_ccm.sh" ]] || fail "custom CCM HelmChartProxy renderer must be gone"
grep -q 'render_cluster.sh' "${ROOT}/scripts/08-create-cluster.sh" || fail "step 8 must render the cluster"
if grep -q 'HelmChartProxy\|cilium.yaml\|render_ccm.sh' "${ROOT}/scripts/08-create-cluster.sh"; then
  fail "step 8 still applies a custom HelmChartProxy"
fi

export CLUSTER_NAME=kairos-capi KUBERNETES_VERSION=v1.35.8 PREFIX=harbor.example/kairos
export NUTANIX_SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA key'
export CONTROL_PLANE_ENDPOINT_IP=10.0.0.5 NUTANIX_ENDPOINT=prism.example
export NUTANIX_PRISM_ELEMENT_CLUSTER_NAME=pe-1 NUTANIX_SUBNET_NAME=subnet-1
unset NUTANIX_CA_FILE NUTANIX_INSECURE

rendered="$(bash "${ROOT}/scripts/render_cluster.sh")"
printf '%s\n' "${rendered}" | grep -q '192.168.0.0/16' || fail "default pod cidr"
printf '%s\n' "${rendered}" | grep -q '10.128.0.0/12' || fail "default service cidr"
printf '%s\n' "${rendered}" | grep -q 'provider: Cilium' || fail "cilium addon"
printf '%s\n' "${rendered}" | grep -q 'name: kairos-capi-cilium-cni-helm-values' || fail "cilium values ref"
printf '%s\n' "${rendered}" | grep -q 'kind: ConfigMap' || fail "cilium values configmap"
printf '%s\n' "${rendered}" | grep -q 'masquerade: true' || fail "bpf masquerade"
printf '%s\n' "${rendered}" | grep -q 'datapathMode: netkit' || fail "cilium netkit"
printf '%s\n' "${rendered}" | grep -q 'mode: multi-pool' || fail "cilium multi-pool"
printf '%s\n' "${rendered}" | grep -q 'autoCreateCiliumPodIPPools' || fail "default cilium pod ip pool"
printf '%s\n' "${rendered}" | grep -q 'kubeProxyReplacement: true' || fail "custom values must keep kube-proxy replacement"
printf '%s\n' "${rendered}" | grep -q 'mode: disabled' || fail "kube-proxy must be disabled"
printf '%s\n' "${rendered}" | grep -q 'strategy: HelmAddon' || fail "helm addon strategy"
printf '%s\n' "${rendered}" | grep -q 'name: nutanix-credentials' || fail "ccm credential secret"
printf '%s\n' "${rendered}" | grep -q 'insecure: false' || fail "default tls verify"
printf '%s\n' "${rendered}" | grep -q 'https://prism.example:9440' || fail "prism url"
if printf '%s\n' "${rendered}" | grep -E -q 'HelmChartProxy|additionalTrustBundle|\$\{'; then
  fail "unexpected proxy, trust bundle, or unsubstituted var: ${rendered}"
fi

export NUTANIX_INSECURE=1
insecure="$(bash "${ROOT}/scripts/render_cluster.sh")"
printf '%s\n' "${insecure}" | grep -q 'insecure: true' || fail "NUTANIX_INSECURE=1"

ca="$(mktemp)"
trap 'rm -f "${ca}"' EXIT
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'MII' '-----END CERTIFICATE-----' >"${ca}"
export NUTANIX_CA_FILE="${ca}"
bundled="$(bash "${ROOT}/scripts/render_cluster.sh")"
printf '%s\n' "${bundled}" | grep -q 'insecure: false' || fail "CA file forces verify"
printf '%s\n' "${bundled}" | grep -q '^            additionalTrustBundle: "' || fail "trust bundle indent"
b64="$(printf '%s\n' "${bundled}" | sed -n 's/^            additionalTrustBundle: "\(.*\)"/\1/p')"
[[ -n "${b64}" ]] || fail "trust bundle value"
decoded="$(printf '%s' "${b64}" | base64 -d)"
[[ "${decoded}" == "$(cat "${ca}")" ]] || fail "trust bundle is the PEM: ${decoded}"

echo "ok cluster_addons_test"
