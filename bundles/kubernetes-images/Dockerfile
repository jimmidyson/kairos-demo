FROM docker.io/mesosphere/nkp-image-builder:v2.17.0-rc.1 AS nib
FROM ghcr.io/mesosphere/mindthegap:v1.25.1 AS mindthegap

FROM ubuntu:24.04 AS ubuntu

ARG CONTAINERD_VERSION=2.1.4
ARG RUNC_VERSION=1.3.2

RUN apt-get update && apt-get install -y curl

WORKDIR /

COPY --from=nib /opt/container-images/ /opt/container-images
COPY --from=mindthegap /ko-app/mindthegap /usr/local/bin/mindthegap

RUN curl -sSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /tmp && cp /tmp/bin/* /usr/local/bin/

RUN curl -SL -o /usr/local/bin/runc "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" \
    && chmod +x /usr/local/bin/runc

RUN mkdir -p /run/containerd /var/lib/containerd

RUN containerd \
    --root /var/lib/containerd \
    --state /run/containerd \
    & \
    sleep 5 && \
    mindthegap import image-bundle --image-bundle /opt/container-images/*.tar && \
    pkill containerd

FROM scratch
COPY run.sh / 
COPY --from=ubuntu /var/lib/containerd /var/lib/containerd