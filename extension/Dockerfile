# syntax=docker/dockerfile:1

ARG GO_VERSION=1.26.5

FROM golang:${GO_VERSION} AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ENV CGO_ENABLED=0
RUN go build -o /inplace-extension ./cmd/inplace-extension

FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /inplace-extension /usr/local/bin/inplace-extension
# Numeric user has no home. SSH writes known_hosts under /tmp.
ENV HOME=/tmp
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/inplace-extension"]
CMD ["serve"]
