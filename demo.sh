#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Discover script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

function print() {
  if [ -t 0 ]; then
    prefix='\033[34;1m▶\033[0m'
  else
    prefix='=>'
  fi
  printf "${prefix} ${1}\n"
}

readonly KAIROS_KIND_CLUSTER_NAME="${KAIROS_KIND_CLUSTER_NAME:-kairos-demo}"

readonly KUBECONFIG="${SCRIPT_DIR}/kairos-kind.kubeconfig"
export KUBECONFIG

if kind get clusters | grep -q '^kairos-demo$'; then
  print "KIND cluster ${KAIROS_KIND_CLUSTER_NAME} already exists"
else
  print 'Getting latest available KIND node version'
  LATEST_KIND_NODE_VERSION="ghcr.io/mesosphere/kind-node:$(crane ls ghcr.io/mesosphere/kind-node | grep -v 64 | sort -rV | head -1)"
  readonly LATEST_KIND_NODE_VERSION

  print "Creating KIND cluster ${KAIROS_KIND_CLUSTER_NAME}..."
  kind create cluster --name "${KAIROS_KIND_CLUSTER_NAME}" --image "${LATEST_KIND_NODE_VERSION}"
fi

if helm status -n cert-manager cert-manager 2>/dev/null | grep -q '^STATUS: deployed$'; then
  print 'cert-manager is already installed'
else
  print 'Installing cert-manager...'
  helm upgrade --install \
    cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version v1.19.1 \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait --wait-for-jobs \
    --hide-notes
fi

if helm status -n kairos-system kairos-crds 2>/dev/null | grep -q '^STATUS: deployed$'; then
  print 'Kairos CRDs are already installed'
else
  print 'Installing Kairos CRDs...'
  helm upgrade --install \
    kairos-crds kairos-crds \
    --repo https://kairos-io.github.io/helm-charts \
    --namespace kairos-system \
    --create-namespace \
    --wait --wait-for-jobs \
    --hide-notes
fi

print 'Building latest osbuilder image to pull in necessary fixes for auroraboot invocation...'
osbuilder_tmpdir="$(mktemp -d)"
trap 'rm -rf "${osbuilder_tmpdir}"' EXIT
git clone --depth 1 --branch 3779-fix-cloud-image-building --single-branch https://github.com/kairos-io/osbuilder.git "${osbuilder_tmpdir}"
pushd "${osbuilder_tmpdir}" &>/dev/null
make docker-build
kind load docker-image quay.io/kairos/osbuilder:test --name "${KAIROS_KIND_CLUSTER_NAME}"
popd &>/dev/null

if helm status -n kairos-system kairos-osbuilder 2>/dev/null | grep -q '^STATUS: deployed$'; then
  print 'Kairos osbuiler is already installed'
else
  print 'Installing Kairos osbuilder...'
  helm upgrade --install \
    kairos-osbuilder osbuilder \
    --repo https://kairos-io.github.io/helm-charts \
    --namespace kairos-system \
    --create-namespace \
    --wait --wait-for-jobs \
    --hide-notes \
    --set-string=image.tag=test \
    --set-string=toolsImage.tag=v0.14.0
fi

if ! kubectl get osartifacts/hello-kairos 2>/dev/null ; then
	cat <<'EOF' | kubectl apply --server-side -f -
kind: Secret
apiVersion: v1
metadata:
  name: cloud-config
stringData:
  userdata: |
    #cloud-config
    users:
    - name: "kairos"
      passwd: "kairos"
    install:
      device: "auto"
      reboot: true
      poweroff: false
      auto: true # Required, for automated installations
---
kind: OSArtifact
apiVersion: build.kairos.io/v1alpha2
metadata:
  name: hello-kairos
spec:
  imageName: "quay.io/kairos/ubuntu:24.04-core-amd64-generic-v3.6.0"
  iso: true
  cloudConfigRef:
    name: cloud-config
    key: userdata
  exporters:
    - template:
        spec:
          restartPolicy: Never
          containers:
          - name: upload
            image: quay.io/curl/curl
            command:
            - /bin/sh
            args:
            - -c
            - |
                for f in $(ls /artifacts)
                do
                curl -T /artifacts/$f http://osartifactbuilder-operator-osbuilder-nginx.kairos-system.svc/upload/$f
                done
            volumeMounts:
            - name: artifacts
              mountPath: /artifacts
EOF
fi

kubectl wait --for=jsonpath='{.status.phase}'=Ready osartifacts/hello-kairos

kubectl get --raw \
	'/api/v1/namespaces/kairos-system/services/osartifactbuilder-operator-osbuilder-nginx/proxy/hello-kairos.iso' | \
	pv \
	>hello-kairos.iso
