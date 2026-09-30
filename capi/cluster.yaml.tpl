apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  topology:
    classRef:
      name: nutanix-quick-start
    version: ${KUBERNETES_VERSION}
    controlPlane:
      replicas: 1
    variables:
    - name: clusterConfig
      value:
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
