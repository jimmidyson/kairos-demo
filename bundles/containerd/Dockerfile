FROM alpine:latest AS containerd-binaries
ARG CONTAINERD_VERSION=2.1.4
ARG RUNC_VERSION=1.3.2
RUN apk add --no-cache curl

WORKDIR /opt/containerd/bin

# Download containerd
RUN curl -sSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" | tar -xz

# Download runc
RUN curl -SL -o runc "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"

RUN chmod +x runc

FROM scratch
COPY run.sh /
COPY --from=containerd-binaries /opt/containerd/bin /opt/containerd/bin/