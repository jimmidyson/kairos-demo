# Combined bundle for CNI plugins, containerd, and kubernetes
ARG CNI_PLUGINS_VERSION=1.8.0
ARG CONTAINERD_VERSION=2.1.4
ARG RUNC_VERSION=1.3.2
ARG KUBERNETES_VERSION=1.34.1
ARG CRICTL_VERSION=1.34.0

# Build CNI plugins
FROM alpine:latest AS cni-plugins
ARG CNI_PLUGINS_VERSION
WORKDIR /opt/cni/bin
RUN apk add --no-cache curl tar
RUN curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"
RUN tar Cxzvf /opt/cni/bin "cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"
RUN chmod +x /opt/cni/bin/*

# Build containerd binaries
FROM alpine:latest AS containerd-binaries
ARG CONTAINERD_VERSION
ARG RUNC_VERSION
RUN apk add --no-cache curl
WORKDIR /tmp
RUN curl -sSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" | tar -xz
RUN curl -SL -o /tmp/bin/runc "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
RUN chmod +x /tmp/bin/runc

# Build kubernetes binaries
FROM alpine:latest AS k8s-binaries
ARG KUBERNETES_VERSION
ARG CRICTL_VERSION
RUN apk add --no-cache curl jq
WORKDIR /opt/kubernetes/bin
RUN curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz" | tar -xz
RUN curl -L -o kubeadm "https://dl.k8s.io/v${KUBERNETES_VERSION}/bin/linux/amd64/kubeadm"
RUN curl -L -o kubelet "https://dl.k8s.io/v${KUBERNETES_VERSION}/bin/linux/amd64/kubelet"
RUN curl -L -o kubectl "https://dl.k8s.io/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
RUN chmod +x kubeadm kubelet kubectl crictl

# Final stage: combine everything into systemd extension structure
FROM alpine:latest AS extension-builder
RUN apk add --no-cache squashfs-tools

# Copy all binaries
COPY --from=cni-plugins /opt/cni/bin/ /extension/opt/cni/bin/
COPY --from=containerd-binaries /tmp/bin/ /extension/usr/bin/
COPY --from=k8s-binaries /opt/kubernetes/bin/ /extension/usr/bin/

# Copy systemd service files
COPY containerd.service /extension/usr/lib/systemd/system/containerd.service
COPY kubelet.service /extension/usr/lib/systemd/system/kubelet.service
COPY 10-kubeadm.conf /extension/etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# Create systemd extension metadata
RUN mkdir -p /extension/usr/lib/extension-release.d && \
    echo "ID=ubuntu" > /extension/usr/lib/extension-release.d/extension-release.kubernetes && \
    echo "VERSION_ID=24.04" >> /extension/usr/lib/extension-release.d/extension-release.kubernetes

RUN mksquashfs /extension /kubernetes.sysext.raw -comp xz

FROM scratch
COPY --from=extension-builder /kubernetes.sysext.raw /kubernetes.sysext.raw
COPY run.sh /