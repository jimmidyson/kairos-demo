ARG KUBERNETES_VERSION=1.34.1
ARG CRICTL_VERSION=1.34.0

FROM alpine:latest AS k8s-binaries
ARG KUBERNETES_VERSION
ARG CRICTL_VERSION

RUN apk add --no-cache curl jq

WORKDIR /opt/kubernetes/bin
# Download crictl
RUN curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz" | tar -xz

# Download kubeadm, kubelet, kubectl
RUN curl -L -o kubeadm "https://dl.k8s.io/v${KUBERNETES_VERSION}/bin/linux/amd64/kubeadm"
RUN curl -L -o kubelet "https://dl.k8s.io/v${KUBERNETES_VERSION}/bin/linux/amd64/kubelet"
RUN curl -L -o kubectl "https://dl.k8s.io/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"

RUN chmod +x kubeadm kubelet kubectl crictl

FROM scratch
COPY run.sh /
COPY --from=k8s-binaries /opt/kubernetes/bin/ /opt/kubernetes/bin/