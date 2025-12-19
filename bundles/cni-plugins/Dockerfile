FROM alpine:latest AS cni-plugins
ARG CNI_PLUGINS_VERSION=1.8.0

WORKDIR /opt/cni/bin
RUN apk add --no-cache curl tar

RUN curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"
RUN tar Cxzvf /opt/cni/bin "cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"

RUN chmod +x /opt/cni/bin/*

FROM scratch
COPY --from=cni-plugins /opt/cni/bin/ /opt/cni/bin/
COPY run.sh /