# Kairos CAPI FIPS factory

Builds the hardened Kairos OS disk the cluster boots (Ubuntu 24.04 amd64 by default; set `OSES` and `ARCHES` for Ubuntu 22.04, Rocky 9, or arm64), runtime **sysexts** for containerd and Kubernetes, and FIPS-rebuilt kubeadm images. A stepped script stands up a CAPX cluster on Nutanix and in-place upgrades v1.36.5 → v1.37.1. The management cluster is KIND, or `container k8s` on macOS when Apple's `container` CLI is installed.

**OS hardening (best-effort in an image build):**

| OS | FIPS | CIS L1 server | DISA STIG |
|---|---|---|---|
| Ubuntu 22.04 / 24.04 | Ubuntu Pro `fips-updates` (or `fips`) | `usg fix cis_level1_server` | `usg fix disa_stig` if that USG release has the profile |
| Rocky 9 | `fips-mode-setup --enable` | OpenSCAP `cis_server_l1` on `ssg-rl9-ds.xml` | OpenSCAP `stig` on the same datastream |
| RHEL 9 | same as Rocky | same, datastream `ssg-rhel9-ds.xml` | same |

RHEL is not in the default `OSES` list (needs a Red Hat registry pull). Set `BASE_IMAGE` to a RHEL 9 image and use `image/Dockerfile.rocky` + `harden-el.sh` if you have one. CIS then STIG (STIG wins conflicts). Many SCAP/USG rules need a real boot and will report findings during `docker build`; that does not fail the build on Rocky. Ubuntu CIS fix is required; STIG is skipped if USG has no `disa_stig` profile.

Design: [`docs/superpowers/specs/2026-08-25-capi-kairos-fips-design.md`](docs/superpowers/specs/2026-08-25-capi-kairos-fips-design.md)

## What this is not

Not a Kairos Kubernetes provider. Not first-boot `kubeadm init`. Bootstrap is **CABPK** only. Cilium and Nutanix CCM are deployed by **CAREN** (`clusterConfig.addons`, HelmAddon via CAAPH), not baked into the image. kube-proxy is disabled; Cilium is the dataplane. arm64 is build-and-push only (no CAPX).

## Prerequisites

```bash
devbox shell
```

Need binfmt/qemu for the non-host architecture, a Harbor project you can push to (e.g. `harbor.eng.nutanix.com`), Ubuntu Pro token, Prism credentials, and `openssl` (extension serving cert and Prism request ids). Docker 24.0.6 / BuildKit v0.11.6 commits a large `RUN --mount` as whiteouts of `/`, so the next step has no `/bin/sh`. Docker 29.8.1 / BuildKit v0.33.0 does not. The minimum in between was not found, so the check rejects anything older than that known-good pair. `KAIROS_SKIP_DOCKER_CHECK=1` skips it. `devbox shell` provides Go, clusterctl, kind, kubectl, jq, crane, and the AWS CLI (the lock resolves Go 1.27.0 and clusterctl 1.13.4). Step 6 uses the AWS CLI for the Prism Objects upload. Step 7 installs core, kubeadm bootstrap, and kubeadm control plane at `CAPI_VERSION` (default `v1.13.6`), CAPX at `CAPX_VERSION` (default `v1.10.3`), CAAPH at `CAAPH_VERSION` (default `v0.6.4`), and CAREN at `CAREN_VERSION` (default `v0.50.0`). Image builds pass `GO_VERSION` (default `1.27.1`) so the FIPS alias is the one that exists on that toolchain.

On macOS, if `container` is on `PATH`, image builds use `container build` and the management cluster is `container k8s` (`KAIROS_BUILDER=auto`, `KAIROS_MGMT=auto`). Set either to `docker` or `kind` to keep that half on Docker/KIND. Multi-arch indexes are `crane index append`. Apple container refuses a Dockerfile larger than 16KiB.

Step 3 pushes the rootfs and runs AuroraBoot without a Docker socket. The socket would give that container the host Docker daemon, which is root on the machine. AuroraBoot pulls the rootfs with its own registry client. A rootfs tag already in the registry is not rebuilt; delete that tag to build it again. AuroraBoot and the packed sysext still run. The packed sysext is pushed as well.

## Environment

```bash
export OCI_REGISTRY=harbor.eng.nutanix.com
export OCI_REPOSITORY_PREFIX=your-project
export OCI_REGISTRY_USERNAME=...
export OCI_REGISTRY_PASSWORD=...
export UBUNTU_PRO_TOKEN=...
export NUTANIX_ENDPOINT=...
export NUTANIX_USER=...
export NUTANIX_PASSWORD=...
export NUTANIX_PRISM_ELEMENT_CLUSTER_NAME=...
export NUTANIX_SUBNET_NAME=...
export NUTANIX_SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA...'
export CONTROL_PLANE_ENDPOINT_IP=...   # kube-vip address for the workload API
```

Optional: `KAIROS_SKIP_DOCKER_CHECK=1` (build on a Docker/BuildKit pair older than the only one known to work), `KAIROS_IMAGE_VERSION` (default `v0.1.0`, must be semver — kairos-init rejects git SHAs), `KUBERNETES_VERSION_OLD` (default `v1.36.5`), `KUBERNETES_VERSION_NEW` (default `v1.37.1`), `NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME` (default `kairos-ubuntu-24.04-amd64-<UTC timestamp>`), `NUTANIX_OBJECTS_ENDPOINT` (default `$NUTANIX_ENDPOINT/api/prism/v4.0/objects/`), `NUTANIX_OBJECTS_BUCKET` (default `vmm-images`), `NUTANIX_OBJECTS_REGION` (default `us-east-1`), `NUTANIX_OBJECTS_ACCESS_KEY` and `NUTANIX_OBJECTS_SECRET_KEY` (default: base64 of `$NUTANIX_USER:$NUTANIX_PASSWORD`), `NUTANIX_CA_FILE` (PEM Prism trusts), `NUTANIX_INSECURE=1` (skip Prism TLS verify), `SSH_IDENTITY_FILE` (private key matching `NUTANIX_SSH_AUTHORIZED_KEY`; optional, generated at `build/extension-ssh-key` if not set), `KAIROS_OPERATOR_REF` (default `v0.2.2`), `DESTROY_PRISM=0` (step 10 leaves the Prism image), `BASE_IMAGE` (required when `OSES` includes `rhel-9`).

## Run

```bash
./demo.sh          # steps 1–10
./demo.sh 1        # env + Harbor login
./demo.sh 8        # create cluster only (after 1–7)
```

| Step | Script | Does |
|---:|---|---|
| 1 | `scripts/01-check-env.sh` | Required env, registry login |
| 2 | `scripts/02-build-bases.sh` | FIPS Kairos OCI bases |
| 3 | `scripts/03-build-sysexts.sh` | `containerd` + `kubernetes` sysexts via AuroraBoot |
| 4 | `scripts/04-build-k8s-images.sh` | FIPS kubeadm images; names and tags from `kubeadm config images list` |
| 5 | `scripts/05-osartifact.sh` | Management cluster, kairos-operator v0.2.2, nginx, cloud disks |
| 6 | `scripts/06-upload-prism.sh` | Prism image, waited until COMPLETE |
| 7 | `scripts/07-capi-init.sh` | clusterctl CAPX + CAAPH + CAREN, `InPlaceUpdates`, Runtime Extension |
| 8 | `scripts/08-create-cluster.sh` | 1 CP + 1 worker at v1.36.5; CAREN deploys Cilium and CCM |
| 9 | `scripts/09-inplace-upgrade.sh` | Patch the topology version; the extension upgrades the same Machines to v1.37.1 |
| 10 | `scripts/10-destroy.sh` | Delete cluster and Prism image (`DESTROY_KIND=1` also drops the management cluster) |

`prepare-kubernetes-node --registry $OCI_REGISTRY/$OCI_REPOSITORY_PREFIX --kubernetes-version v1.36.5` is the only node-local installer. CAPI `preKubeadmCommands` runs it on first boot. Step 7 registers the in-place Runtime Extension; step 9 only patches the Kubernetes version. The extension SSHes `prepare-kubernetes-node` and `kubeadm upgrade` so the update stays on the existing VMs. The extension pod uses the management node's network. On Docker Desktop that is the Linux VM; with `container k8s` it is the Apple container VM. AHV addresses have to be reachable from there.

FIPS packages are installed between `kairos-init -s install` and `-s init`, and `fips=1` is appended to `/etc/default/grub` before the UKI is built. The containerd sysext is compiled on the matching distro image (`ubuntu:24.04`, `rockylinux:9`), not the Kairos image. containerd, runc, and CNI plugins are built with `GOFIPS140=certified`. The kubernetes sysext ships crictl for that Kubernetes minor. Kubeadm image names and tags, including pause, come from `kubeadm config images list` and are pushed as a manifest list. `prepare-kubernetes-node` reads `/usr/lib/kairos/pause-tag` from the kubernetes sysext and writes a containerd 2 sandbox pin.

## Checks (not a cluster e2e)

```bash
bash tests/lib_test.sh
bash tests/prepare-kubernetes-node_test.sh
bash tests/image_contract_test.sh
bash tests/sysext_names_test.sh
bash tests/k8s_images_list_test.sh
bash tests/prism_test.sh
bash tests/cluster_addons_test.sh
( cd extension && go test ./... )
```

## Image names

Prefix = `$OCI_REGISTRY/$OCI_REPOSITORY_PREFIX`

- `base:ubuntu-24.04-amd64` (and the other OS/arch tags)
- `containerd:2.4.0-ubuntu-24.04-amd64`
- `kubernetes:v1.37.1-amd64`
- `kube-apiserver:v1.37.1` (and controller-manager, scheduler, proxy). etcd, coredns, and pause use the name and tag from `kubeadm config images list` for that Kubernetes version (not the Kubernetes version as the tag). kube-proxy is still built; the cluster does not run it. Step 3 pushes `containerd-rootfs` and `kubernetes-rootfs` so AuroraBoot can pull them, then pushes the packed sysext.
