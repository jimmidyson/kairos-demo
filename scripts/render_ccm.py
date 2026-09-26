#!/usr/bin/env python3
"""Render the Nutanix CCM HelmChartProxy.

nutanix.github.io/helm-releases is the NCM product index, not this chart.
The cloud-provider chart is published from nutanix-cloud-native/cloud-provider-nutanix.
Override with NUTANIX_CCM_REPO / NUTANIX_CCM_CHART / NUTANIX_CCM_CHART_VERSION.
"""

import json
import os
import sys


def q(value: str) -> str:
    return json.dumps(value)


def values_yaml(endpoint: str, user: str, password: str, ca_pem: str, insecure: bool) -> str:
    lines = [
        "config:",
        "  prismCentral:",
        "    address: %s" % q(endpoint),
        "    port: 9440",
        "    username: %s" % q(user),
        "    password: %s" % q(password),
        "    insecure: %s" % ("true" if insecure else "false"),
    ]
    if ca_pem:
        lines.append("    additionalTrustBundle: |")
        for line in ca_pem.splitlines():
            lines.append("      " + line)
    return "\n".join(lines)


def manifest() -> str:
    endpoint = os.environ["NUTANIX_ENDPOINT"]
    user = os.environ["NUTANIX_USER"]
    password = os.environ["NUTANIX_PASSWORD"]
    repo = os.environ.get("NUTANIX_CCM_REPO") or "https://nutanix-cloud-native.github.io/cloud-provider-nutanix"
    chart = os.environ.get("NUTANIX_CCM_CHART") or "nutanix-cloud-provider"
    version = os.environ.get("NUTANIX_CCM_CHART_VERSION") or ""
    insecure = os.environ.get("NUTANIX_INSECURE") == "1"
    ca_pem = ""
    ca_file = os.environ.get("NUTANIX_CA_FILE") or ""
    if ca_file:
        with open(ca_file) as f:
            ca_pem = f.read().strip()
        insecure = False
    body = values_yaml(endpoint, user, password, ca_pem, insecure)
    indented = "\n".join("    " + line if line else "" for line in body.splitlines())
    version_line = ('  version: "%s"\n' % version) if version else ""
    return """apiVersion: addons.cluster.x-k8s.io/v1alpha1
kind: HelmChartProxy
metadata:
  name: nutanix-ccm
spec:
  clusterSelector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: kairos-capi
  repoURL: %s
  chartName: %s
  releaseName: nutanix-ccm
  namespace: kube-system
%s  valuesTemplate: |
%s
""" % (q(repo), q(chart), version_line, indented)


if __name__ == "__main__":
    sys.stdout.write(manifest())
