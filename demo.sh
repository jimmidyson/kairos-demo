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

if kind get clusters 2>/dev/null | grep -q '^kairos-demo$'; then
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

kubectl apply -k https://github.com/kairos-io/kairos-operator/config/default

print "Ensuring registry secret is up to date to be able to push images to ${OCI_REGISTRY}"
kubectl create secret docker-registry oci-registry-secret \
  --dry-run=client -o yaml \
  --docker-server="${OCI_REGISTRY}" \
  --docker-username="${OCI_REGISTRY_USERNAME}" \
  --docker-password="${OCI_REGISTRY_PASSWORD}" \
  | kubectl apply --server-side -f -

for arch in arm64 amd64; do
  if ! kubectl get osartifacts/base-image-${arch} 2>/dev/null ; then
    print "Building CIS hardened base image for ${arch}..."
    kubectl create secret generic base-oci-spec-${arch} \
      --dry-run=client -o yaml \
      --from-file=ociSpec="${SCRIPT_DIR}/dockerfiles/Dockerfile.base" \
      --from-literal=ubuntuProToken="${UBUNTU_PRO_TOKEN}" \
      | kubectl apply --server-side -f -
    cat <<EOF | kubectl apply --server-side -f -
kind: OSArtifact
apiVersion: build.kairos.io/v1alpha2
metadata:
  name: base-image-${arch}
spec:
  image:
    ociSpec:
      ref:
        name: base-oci-spec
      buildContextVolume: build-context
      templateValues:
        BaseImage: "ubuntu:24.04"
        KairosInitVersion: "v0.8.5"
        Version: "${VERSION}"
        Model: "generic"
    buildImage:
      registry: "${OCI_REGISTRY}"
      repository: "${OCI_REPOSITORY_PREFIX}/base-image"
      tag: "${VERSION}-ubuntu-24.04-${arch}"
    push: true
    imageCredentialsSecretRef:
      name: oci-registry-secret
  volumes:
    - name: build-context
      secret:
        secretName: base-oci-spec
  artifacts:
    arch: ${arch}
    iso: true
EOF
  fi
done

kubectl wait --for=jsonpath='{.status.phase}'=Ready osartifacts base-image-{arm64,amd64} --timeout=60m

