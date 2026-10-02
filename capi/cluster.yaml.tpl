apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 192.168.0.0/16
    services:
      cidrBlocks:
      - 10.128.0.0/12
  topology:
    classRef:
      name: nutanix-quick-start
    version: ${KUBERNETES_VERSION}
    controlPlane:
      replicas: 1
    variables:
    - name: clusterConfig
      value:
        addons:
          ccm:
            credentials:
              secretRef:
                name: nutanix-credentials
            strategy: HelmAddon
          cni:
            provider: Cilium
            strategy: HelmAddon
            values:
              sourceRef:
                kind: ConfigMap
                name: ${CLUSTER_NAME}-cilium-cni-helm-values
        kubeProxy:
          mode: disabled
        kubernetesImageRepository: ${PREFIX}
        users:
        - name: capiuser
          sshAuthorizedKeys:
          - ${NUTANIX_SSH_AUTHORIZED_KEY}
          sudo: "ALL=(ALL) NOPASSWD:ALL"
        nutanix:
          controlPlaneEndpoint:
            host: ${CONTROL_PLANE_ENDPOINT_IP}
            port: 6443
            virtualIP: {}
          prismCentralEndpoint:
            credentials:
              secretRef:
                name: nutanix-credentials
            url: https://${NUTANIX_ENDPOINT}:9440
            insecure: ${PRISM_INSECURE}${PRISM_TRUST_LINE}
        controlPlane:
          nutanix:
            machineDetails:
              bootType: uefi
              cluster:
                name: ${NUTANIX_PRISM_ELEMENT_CLUSTER_NAME}
                type: name
              imageLookup:
                baseOS: ubuntu-24.04
                format: kairos-{{.BaseOS}}-amd64-*
              memorySize: 4Gi
              subnets:
              - name: ${NUTANIX_SUBNET_NAME}
                type: name
              systemDiskSize: 40Gi
              vcpuSockets: 2
              vcpusPerSocket: 1
    - name: workerConfig
      value:
        nutanix:
          machineDetails:
            bootType: uefi
            cluster:
              name: ${NUTANIX_PRISM_ELEMENT_CLUSTER_NAME}
              type: name
            imageLookup:
              baseOS: ubuntu-24.04
              format: kairos-{{.BaseOS}}-amd64-*
            memorySize: 4Gi
            subnets:
            - name: ${NUTANIX_SUBNET_NAME}
              type: name
            systemDiskSize: 40Gi
            vcpuSockets: 2
            vcpusPerSocket: 1
    workers:
      machineDeployments:
      - class: default-worker
        name: workers
        replicas: 1
