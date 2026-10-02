# CAREN v0.50 default Cilium values for kube-proxy replacement on non-EKS
# (addons/cni/cilium/values-template.yaml). A custom ConfigMap replaces that
# template, and the admission webhook only renders ControlPlaneEndpoint, so
# the Provider and EnableKubeProxyReplacement branches are expanded here.
# Additions are bpf.masquerade, netkit, and multi-pool IPAM. The default pool is the
# cluster pod CIDR. preflight-values.yaml is required:
# upgrades read that key from this same ConfigMap.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CLUSTER_NAME}-cilium-cni-helm-values
  namespace: default
data:
  values.yaml: |
    cni:
      exclusive: false
    hubble:
      enabled: true
      tls:
        auto:
          enabled: true               # enable automatic TLS certificate generation
          method: cronJob             # auto generate certificates using cronJob method
          certValidityDuration: 60    # certificates validity duration in days (default 2 months)
          schedule: "0 0 1 * *"       # schedule on the 1st day regeneration of each month
      relay:
        enabled: true
        tls:
          server:
            enabled: true
            mtls: true
        image:
          useDigest: false
        priorityClassName: system-cluster-critical
    ipam:
      mode: multi-pool
      operator:
        autoCreateCiliumPodIPPools:
          default:
            ipv4:
              cidrs:
              - 192.168.0.0/16
              maskSize: 24
    image:
      useDigest: false
    operator:
      image:
        useDigest: false
    certgen:
      image:
        useDigest: false
    socketLB:
      hostNamespaceOnly: true
    envoy:
      image:
        useDigest: false
    k8sServiceHost: "{{ trimPrefix .ControlPlaneEndpoint.Host "https://" }}"
    k8sServicePort: "{{ .ControlPlaneEndpoint.Port }}"
    kubeProxyReplacement: true
    tunnelProtocol: geneve
    loadBalancer:
      mode: dsr
      dsrDispatch: geneve
    bpf:
      masquerade: true
      datapathMode: netkit
  preflight-values.yaml: |
    agent: false
    operator:
      enabled: false
    preflight:
      enabled: true
      envoy:
        image:
          useDigest: false
      image:
        useDigest: false
    k8sServiceHost: "{{ trimPrefix .ControlPlaneEndpoint.Host "https://" }}"
    k8sServicePort: "{{ .ControlPlaneEndpoint.Port }}"
