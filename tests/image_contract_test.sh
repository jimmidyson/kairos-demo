#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -q 'kubeadm init' "${ROOT}/image/cloud-config.yaml" && fail "OEM cloud-config must not kubeadm init"
grep -q 'prepare-kubernetes-node' "${ROOT}/image/cloud-config.yaml" && fail "OEM must not call prepare-kubernetes-node; CAPI preKubeadmCommands owns that"
grep -q 'nkpadmin' "${ROOT}/image/cloud-config.yaml" || fail "missing debug user"
grep -q 'kairos-custom-hostname' "${ROOT}/scripts/08-create-cluster.sh" && fail "hostname is OEM cloud-config, not a kubeadm file"
grep -q 'ds.meta_data.hostname' "${ROOT}/image/cloud-config.yaml" || fail "hostname must use instance metadata"
grep -q '127.0.0.1 localhost' "${ROOT}/image/cloud-config.yaml" || fail "hosts must include ipv4 localhost"
grep -q '127.0.1.1 {{ ds.meta_data.hostname }}' "${ROOT}/image/cloud-config.yaml" || fail "hosts must map the hostname"
grep -q '::1 localhost ip6-localhost ip6-loopback' "${ROOT}/image/cloud-config.yaml" || fail "hosts must include ipv6 localhost"
# shellcheck source=../versions.env
source "${ROOT}/versions.env"
case "${KAIROS_IMAGE_VERSION}" in
  v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "KAIROS_IMAGE_VERSION=${KAIROS_IMAGE_VERSION} is not semver" ;;
esac
grep -q 'git describe' "${ROOT}/scripts/02-build-bases.sh" && fail "02-build-bases must not feed git describe to kairos-init"
for f in image/harden-ubuntu.sh image/harden-el.sh; do
  [[ -f "${ROOT}/${f}" ]] || fail "missing ${f}"
done
grep -q 'pro enable usg' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: enable usg (not only fips)"
grep -q 'cis_level1_server' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: CIS L1"
grep -q 'disa_stig' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: STIG"
grep -q 'fips' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu: FIPS"
# The old `pro enable fips || pro enable usg` skips USG when FIPS works.
grep -E 'pro enable fips.*\|\|.*pro enable usg' "${ROOT}/image/harden-ubuntu.sh" && fail "ubuntu: FIPS must not skip USG"
grep -q 'fips-mode-setup' "${ROOT}/image/harden-el.sh" || fail "el: FIPS"
grep -q 'cis_server_l1' "${ROOT}/image/harden-el.sh" || fail "el: CIS L1"
grep -q 'profile_stig\|/stig' "${ROOT}/image/harden-el.sh" || fail "el: STIG"
grep -q 'ssg-rl9-ds.xml' "${ROOT}/image/harden-el.sh" || fail "el: Rocky datastream"
grep -q 'ssg-rhel9-ds.xml' "${ROOT}/image/harden-el.sh" || fail "el: RHEL datastream if BASE_IMAGE is RHEL"
grep -q 'fips=1' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu cmdline fips=1"
grep -q 'fips=1' "${ROOT}/image/harden-el.sh" || fail "el cmdline fips=1"
grep -q '/var/lib/ubuntu-advantage/private' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu pro token must be scrubbed"
grep -q 'retrying after mirror sync' "${ROOT}/image/harden-ubuntu.sh" || fail "ubuntu apt-get update must retry a mid-sync mirror"
grep -q 'retrying after mirror sync' "${ROOT}/image/Dockerfile.ubuntu" || fail "ubuntu image apt-get update must retry a mid-sync mirror"
grep -q 'systemctl mask systemd-timesyncd' "${ROOT}/image/Dockerfile.ubuntu" || fail "ubuntu must mask timesyncd after kairos-init"
grep -q 'systemctl enable chrony' "${ROOT}/image/Dockerfile.ubuntu" || fail "ubuntu STIG time source is chrony"
grep -q 'systemd-timesyncd chrony-' "${ROOT}/image/Dockerfile.ubuntu" || fail "timesyncd install must remove chrony"
grep -q 'apt-get purge -y systemd-timesyncd' "${ROOT}/image/Dockerfile.ubuntu" || fail "timesyncd must be purged after kairos-init"
for df in image/Dockerfile.ubuntu image/Dockerfile.rocky; do
  grep -q 'net.ipv4.ip_forward = 1' "${ROOT}/${df}" || fail "${df}: IPv4 forwarding"
  grep -q '/usr/lib/sysctl.d/99-zz-kubernetes.conf' "${ROOT}/${df}" || fail "${df}: sysctl file must be under /usr/lib/sysctl.d"
  grep -q 'ln -s /usr/lib/sysctl.d/99-zz-kubernetes.conf /etc/sysctl.d/99-zz-kubernetes.conf' "${ROOT}/${df}" || fail "${df}: sysctl file must be linked into /etc/sysctl.d"
  grep -q 'net.ipv6.conf.all.forwarding = 1' "${ROOT}/${df}" || fail "${df}: IPv6 forwarding"
  grep -q 'net.bridge.bridge-nf-call-iptables  = 1' "${ROOT}/${df}" || fail "${df}: bridge IPv4 netfilter"
  grep -q 'net.bridge.bridge-nf-call-ip6tables = 1' "${ROOT}/${df}" || fail "${df}: bridge IPv6 netfilter"
  grep -q 'net.core.bpf_jit_enable = 1' "${ROOT}/${df}" || fail "${df}: BPF JIT must be enabled"
  grep -q 'net.core.bpf_jit_harden = 1' "${ROOT}/${df}" || fail "${df}: unprivileged BPF JIT must be hardened"
  grep -q 'kernel.unprivileged_bpf_disabled = 2' "${ROOT}/${df}" || fail "${df}: unprivileged BPF must be disabled"
  grep -q 'net.ipv4.ip_local_reserved_ports = 30000-32767' "${ROOT}/${df}" || fail "${df}: NodePort range must be reserved"
  grep -q 'fs.inotify.max_user_watches = 524288' "${ROOT}/${df}" || fail "${df}: inotify watches"
  grep -q 'fs.inotify.max_user_instances = 8192' "${ROOT}/${df}" || fail "${df}: inotify instances"
  grep -q 'swap.target' "${ROOT}/${df}" || fail "${df}: swap.target must be masked"
  grep -q 'ln -sf /dev/null /etc/systemd/system/swap.target' "${ROOT}/${df}" || fail "${df}: etc swap.target must be masked"
  grep -q 'ln -sf /dev/null /usr/lib/systemd/system/swap.target' "${ROOT}/${df}" || fail "${df}: usr swap.target must be masked"
  grep -q 'sed -i -E.*swap' "${ROOT}/${df}" || fail "${df}: fstab swap entries must be removed"
  grep -q 'COPY image/05-k8s-noswap.yaml /system/oem/05-k8s-noswap.yaml' "${ROOT}/${df}" || fail "${df}: no-swap OEM config must be copied"
done
grep -q 'systemd-zram-setup@zram0.service' "${ROOT}/image/05-k8s-noswap.yaml" || fail "no-swap OEM config must mask zram"
grep -q 'vm.swappiness: "0"' "${ROOT}/image/05-k8s-noswap.yaml" || fail "no-swap OEM config must set swappiness"
grep -q 'swapoff -a' "${ROOT}/image/05-k8s-noswap.yaml" || fail "no-swap OEM config must disable active swap"

order_before() {
  local file="$1" a="$2" b="$3" la lb
  la="$(grep -n -F -- "${a}" "${file}" | head -1 | cut -d: -f1)"
  lb="$(grep -n -F -- "${b}" "${file}" | head -1 | cut -d: -f1)"
  [[ -n "${la}" && -n "${lb}" && "${la}" -lt "${lb}" ]] || fail "${file}: ${a} (line ${la}) must precede ${b} (line ${lb})"
}
for df in image/Dockerfile.ubuntu image/Dockerfile.rocky; do
  grep -q 'COPY --from=kairos-init' "${ROOT}/${df}" && fail "${df}: kairos-init must be mounted, not copied"
  grep -q 'COPY image/harden-' "${ROOT}/${df}" && fail "${df}: harden script must be mounted, not copied"
  grep -q 'source=image/harden-' "${ROOT}/${df}" && fail "${df}: bind-mount image/, not the harden script file"
  grep -q 'source=image,target=/mnt/image' "${ROOT}/${df}" || fail "${df}: harden script must be a directory bind mount"
  grep -q 'type=bind,from=kairos-init' "${ROOT}/${df}" || fail "${df}: kairos-init must be a bind mount"
  grep -q -- '--skip-step' "${ROOT}/${df}" && fail "${df}: install is one kairos-init command"
  order_before "${ROOT}/${df}" '-s install -m' 'harden-'
  order_before "${ROOT}/${df}" 'harden-' '-s init -m'
  order_before "${ROOT}/${df}" 'prepare-kubernetes-node' '-s init -m'
  order_before "${ROOT}/${df}" '-s init -m' 'net.ipv4.ip_forward'
  order_before "${ROOT}/${df}" '-s init -m' 'swap.target'
  order_before "${ROOT}/${df}" '-s init -m' 'modules-load.d'
  order_before "${ROOT}/${df}" '-s init -m' '05-k8s-noswap.yaml'
  order_before "${ROOT}/${df}" 'harden-' 'rsync'
  order_before "${ROOT}/${df}" 'rsync' '-s init -m'
done
order_before "${ROOT}/image/Dockerfile.ubuntu" '-s init -m' 'systemctl mask systemd-timesyncd'
grep -q 'opencontainers/runc' "${ROOT}/sysexts/Dockerfile.containerd" || fail "runc must be built from source"
grep -q 'containernetworking/plugins' "${ROOT}/sysexts/Dockerfile.containerd" || fail "cni must be built from source"
grep -q 'runc.${TARGETARCH}' "${ROOT}/sysexts/Dockerfile.containerd" && fail "runc must not be an upstream release binary"
grep -E '^ARG [A-Za-z0-9_]+=' "${ROOT}/sysexts/Dockerfile.containerd" "${ROOT}/sysexts/Dockerfile.kubernetes" && fail "sysext ARGs take their values from the build, not Dockerfile defaults"
grep -q -F -- 'RELEASE_VERSION=${KUBE_RELEASE_VERSION}' "${ROOT}/scripts/03-build-sysexts.sh" || fail "kubelet unit templates use KUBE_RELEASE_VERSION"
grep -q 'distro_image' "${ROOT}/scripts/03-build-sysexts.sh" || fail "cri build must use the distro image"
grep -q 'oci_build' "${ROOT}/scripts/02-build-bases.sh" || fail "bases use oci_build"
grep -q 'oci_build' "${ROOT}/scripts/03-build-sysexts.sh" || fail "sysexts use oci_build"
grep -q 'oci_build' "${ROOT}/k8s-images/build.sh" || fail "kubeadm images use oci_build"
grep -q 'run_auroraboot_sysext' "${ROOT}/scripts/03-build-sysexts.sh" || fail "sysext packing goes through run_auroraboot_sysext"
grep -q 'registry_image_exists' "${ROOT}/scripts/03-build-sysexts.sh" || fail "rootfs build skips a tag already in the registry"
grep -q 'docker.sock' "${ROOT}/scripts/03-build-sysexts.sh" && fail "step 3 must not mount the docker socket itself"
grep -q 'container run' "${ROOT}/scripts/lib.sh" || fail "apple container runs auroraboot"
grep -q 'docker.sock' "${ROOT}/scripts/lib.sh" && fail "auroraboot must not mount the docker socket"
grep -q 'crane index append' "${ROOT}/k8s-images/build.sh" || fail "manifest list uses crane"
grep -q 'container k8s create' "${ROOT}/scripts/lib.sh" || fail "container k8s create"
grep -q 'mgmt_create' "${ROOT}/scripts/05-osartifact.sh" || fail "step 5 creates the management cluster"
grep -q 'mgmt_build_and_load' "${ROOT}/scripts/07-capi-init.sh" || fail "extension image loads into the management cluster"
grep -q 'KAIROS_OPERATOR_REF' "${ROOT}/scripts/05-osartifact.sh" || fail "operator ref must be pinned"
grep -q 'config/nginx' "${ROOT}/scripts/05-osartifact.sh" || fail "nginx kustomize"
grep -q 'port-forward' "${ROOT}/scripts/05-osartifact.sh" || fail "download via port-forward"
grep -q 'deploy/operator-kairos-operator' "${ROOT}/scripts/05-osartifact.sh" || fail "operator deploy name"
grep -q 'deploy/nginx' "${ROOT}/scripts/05-osartifact.sh" || fail "nginx deploy name"
grep -q 'deploy/kairos-operator-nginx' "${ROOT}/scripts/05-osartifact.sh" && fail "nginx Deployment is named nginx; kairos-operator-nginx is the Service"
grep -q -F -- 'quay.io/kairos/operator:${op_ref}' "${ROOT}/scripts/05-osartifact.sh" || fail "operator image follows KAIROS_OPERATOR_REF"
grep -q -F -- 'imageName:' "${ROOT}/osartifact/cloud-image.yaml.tpl" && fail "v0.2 OSArtifact has no spec.imageName"
grep -q -F -- 'ref: ${BASE_IMAGE}' "${ROOT}/osartifact/cloud-image.yaml.tpl" || fail "OSArtifact source is spec.image.ref"
grep -q -F -- 'cloudImage: true' "${ROOT}/osartifact/cloud-image.yaml.tpl" || fail "OSArtifact still requests a cloud image"
grep -q 'kubernetesImageRepository' "${ROOT}/capi/cluster.yaml.tpl" || fail "cluster sets kubernetesImageRepository"
grep -q 'kairos-prepare-kubernetes-node' "${ROOT}/scripts/08-create-cluster.sh" || fail "clusterclass patch prepares the node"
grep -q '{{ .builtin.controlPlane.version }}' "${ROOT}/scripts/08-create-cluster.sh" || fail "control plane prepare uses the topology version"
grep -q '{{ .builtin.machineDeployment.version }}' "${ROOT}/scripts/08-create-cluster.sh" || fail "worker prepare uses the topology version"
grep -q 'hostname: "{{ ds.meta_data.hostname }}"' "${ROOT}/image/cloud-config.yaml" || fail "OEM cloud-config must set the hostname at boot"
# CABPK userdata is stage-less, so yip reapplies it on every boot stage.
# fs runs before boot; drop the saved file once kubeadm has succeeded.
grep -q '/etc/kubernetes/kubelet.conf' "${ROOT}/image/cloud-config.yaml" || fail "OEM must keep CABPK userdata until kubelet.conf exists"
grep -q 'rm -f /oem/95_userdata/userdata.yaml' "${ROOT}/image/cloud-config.yaml" || fail "OEM must drop CABPK userdata.yaml after kubeadm"
grep -q 'rm -rf /oem/95_userdata' "${ROOT}/image/cloud-config.yaml" && fail "OEM must keep /oem/95_userdata or the datasource pulls kubeadm again"
grep -q 'controlPlaneEndpoint:' "${ROOT}/capi/cluster.yaml.tpl" || fail "Cluster topology must configure a control-plane endpoint"
grep -A3 -q 'controlPlaneEndpoint:[[:space:]]*' "${ROOT}/capi/cluster.yaml.tpl" || fail "Cluster topology control-plane endpoint shape"
grep -q '            virtualIP: {}' "${ROOT}/capi/cluster.yaml.tpl" || fail "Cluster topology must enable kube-vip virtualIP customization"
grep -q 'CAPI_VERSION=' "${ROOT}/versions.env" || fail "CAPI_VERSION pin"
grep -q -- '--core "cluster-api:${CAPI_VERSION}"' "${ROOT}/scripts/07-capi-init.sh" || fail "clusterctl core version"
grep -q -- '--bootstrap "kubeadm:${CAPI_VERSION}"' "${ROOT}/scripts/07-capi-init.sh" || fail "clusterctl bootstrap version"
grep -q -- '--control-plane "kubeadm:${CAPI_VERSION}"' "${ROOT}/scripts/07-capi-init.sh" || fail "clusterctl control-plane version"
echo "ok image_contract_test"
