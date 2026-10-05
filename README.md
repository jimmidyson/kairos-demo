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

| You need | For |
|---|---|
| A Harbor project you can push to (for example `harbor.eng.nutanix.com`) | OCI images |
| An Ubuntu Pro token | Ubuntu FIPS packages |
| Prism credentials: endpoint, user, password, PE cluster, subnet | CAPX and the disk upload |
| `openssl` | Extension serving cert and Prism request ids |
| binfmt/qemu | Any architecture other than the host |
| Docker 29.8.1 / BuildKit v0.33.0 or newer | Image builds |

`devbox shell` supplies Go 1.27.0, clusterctl 1.13.4, kind, kubectl, jq, crane, and the AWS CLI. Step 6 uses the AWS CLI to upload the disk to Prism Objects. Image builds use `GO_VERSION` (default `1.27.1`) so the FIPS alias exists on that toolchain.

Docker 24.0.6 / BuildKit v0.11.6 commits a large `RUN --mount` as whiteouts of `/`, so the next step has no `/bin/sh`. The oldest release that avoids that was not found, so the check accepts only the known-good pair above and anything newer. `KAIROS_SKIP_DOCKER_CHECK=1` skips the check.

On macOS, if `container` is on `PATH`, image builds use `container build` and the management cluster is `container k8s` (`KAIROS_BUILDER=auto`, `KAIROS_MGMT=auto`). Set either to `docker` or `kind` to keep that half on Docker/KIND. Multi-arch indexes are `crane index append`. Apple container refuses a Dockerfile larger than 16KiB.

## Environment

Required:

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

Optional:

| Variable | Default |
|---|---|
| `KUBERNETES_VERSION_OLD` | `v1.36.5` |
| `KUBERNETES_VERSION_NEW` | `v1.37.1` |
| `GO_VERSION` | `1.27.1` |
| `KAIROS_IMAGE_VERSION` | `v0.1.0` (semver; kairos-init rejects git SHAs) |
| `KAIROS_OPERATOR_REF` | `v0.2.2` |
| `KAIROS_SKIP_DOCKER_CHECK` | unset; `1` skips the Docker/BuildKit check |
| `NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME` | `kairos-ubuntu-24.04-amd64-<UTC timestamp>` |
| `NUTANIX_OBJECTS_ENDPOINT` | `$NUTANIX_ENDPOINT/api/prism/v4.0/objects/` |
| `NUTANIX_OBJECTS_BUCKET` | `vmm-images` |
| `NUTANIX_OBJECTS_REGION` | `us-east-1` |
| `NUTANIX_OBJECTS_ACCESS_KEY` / `NUTANIX_OBJECTS_SECRET_KEY` | base64 of `$NUTANIX_USER:$NUTANIX_PASSWORD` |
| `NUTANIX_CA_FILE` | unset; PEM Prism trusts |
| `NUTANIX_INSECURE` | unset; `1` skips Prism TLS verify |
| `SSH_IDENTITY_FILE` | `build/extension-ssh-key`, generated when unset |
| `DESTROY_PRISM` | unset; step 10 deletes the Prism image. `0` leaves it |
| `BASE_IMAGE` | required when `OSES` includes `rhel-9` |

## Run

```bash
./demo.sh          # steps 1–10
./demo.sh 1        # env + Harbor login
./demo.sh 8        # create cluster only (after 1–7)
```

Step 7 installs these providers. Override the variable to pin another release.

| Provider | Variable | Default |
|---|---|---|
| CAPI core, kubeadm bootstrap, kubeadm control plane | `CAPI_VERSION` | `v1.13.6` |
| CAPX | `CAPX_VERSION` | `v1.10.3` |
| CAAPH | `CAAPH_VERSION` | `v0.6.4` |
| CAREN | `CAREN_VERSION` | `v0.50.0` |

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

Step 3 pushes the rootfs and runs AuroraBoot without a Docker socket. The socket would give that container the host Docker daemon, which is root on the machine. AuroraBoot pulls the rootfs with its own registry client. A rootfs tag already in the registry is left as-is; delete that tag to build it again. AuroraBoot and the packed sysext still run, and the packed sysext is pushed.

## Kairos and kubeadm

CABPK is the only bootstrap. The OEM cloud-config does not run `kubeadm`. `prepare-kubernetes-node` is the only node-local installer: CAPI `preKubeadmCommands` runs it on first boot, and the in-place extension SSHes it before `kubeadm upgrade` on the same VM.

| Pitfall | Workaround |
|---|---|
| CABPK userdata has no yip stages. Kairos maps it onto boot, and `cos-setup-boot` reapplies it on every boot, including `write_files` of the PKI. | An OEM `fs` stage deletes `/oem/95_userdata/userdata.yaml` once `/etc/kubernetes/kubelet.conf` exists. The `/oem/95_userdata` directory stays, so the datasource does not pull the config drive again. |
| yip does not render cloud-init datasource templates, so it cannot see the CAPI node name. | The OEM config does not set the hostname. The provider's `hostnamectl` `preKubeadmCommand` sets it. |
| `/etc/hosts` is a symlink to `/usr/local/etc/hosts`. After `systemd-sysext` refreshes, `/usr` is a read-only overlay and writes through the symlink fail. | `rm -f /etc/hosts` and write a regular file. OEM boot does this before the CAPI name exists. A ClusterClass `preKubeadmCommand`, appended after the provider `hostnamectl`, does it again with `127.0.0.1`, `127.0.1.1 <hostname>`, and `::1`. |
| Putting `/opt` in `SYSTEMD_SYSEXT_HIERARCHIES` makes it read-only. Cilium installs into `/opt/cni/bin`. | `/opt` is left out of the hierarchy. Stock CNI plugins ship at `/usr/lib/cni`. containerd `bin_dirs` is `["/opt/cni/bin", "/usr/lib/cni"]`. |
| kubeadm stats `/etc/kubernetes/patches` while applying static-pod patches. | `prepare-kubernetes-node` creates that directory and leaves it empty. |
| containerd 2 pins the sandbox image as `pause:<tag>`. That tag comes from `kubeadm config images list`, and it is not the Kubernetes version. | The kubernetes sysext writes `/usr/lib/kairos/pause-tag`. Prepare reads it after the sysext refresh and writes `etc/containerd/conf.d/capi-sandbox.toml`. A missing tag fails the run. |
| A failed sysext refresh used to be stored as already applied, so the next run skipped it. | The applied-set file is written only after `systemd-sysext refresh` and kubelet start. Extensions are installed before kubelet is stopped, so a failed install leaves kubelet running. |
| CAREN writes the bootstrap templates itself. `preKubeadmCommands` is not a topology variable, and `kubernetesImageRepository` is immutable. | Step 8 patches ClusterClass `nutanix-quick-start` with `prepare-kubernetes-node`, using `{{ .builtin.controlPlane.version }}` and `{{ .builtin.machineDeployment.version }}`. Reapplying the patch replaces a stale command list. Step 9 patches only `spec.topology.version`. |
| Kubernetes components live in sysexts, so a version change is not a stock kubeadm roll of a new VM. | The Runtime Extension covers an in-place update only when the Nutanix image is unchanged and every spec diff is the version string, including inside `preKubeadmCommands`. `UpdateMachine` SSHes as `nkpadmin` from the management cluster network (the Docker or Apple container VM; AHV addresses have to be reachable from there), runs `prepare-kubernetes-node`, then `kubeadm upgrade apply` on the control plane or `kubeadm upgrade node` on a worker. kubeadm's "already at this version" output is treated as success so a retry can finish. |
| v1beta2 `KubeadmControlPlane` has no Ready condition. | Steps 8 and 9 wait for `Available`. |
| `kairos-init -s init` builds the UKI from the rootfs it sees at that step. CIS/STIG remove `rsync`, which dracut needs. On Ubuntu they also install chrony, and chrony conflicts with `systemd-timesyncd`, which `kairos-init` enables. | FIPS packages and `fips=1` in `/etc/default/grub` are applied between `-s install` and `-s init`. `rsync` is reinstalled before init. On Ubuntu, timesyncd is installed for the init step; after init it is purged, chrony is installed, and timesyncd is masked. |
| kubelet requires swap off, IP forwarding, and `overlay` / `br_netfilter` before pods start. | After `-s init`, the image masks `swap.target`, strips swap from `/etc/fstab`, and an OEM config masks zram and runs `swapoff -a`. Sysctls (forwarding, bridge netfilter, BPF JIT, the NodePort range, inotify) are written to `/usr/lib/sysctl.d/99-zz-kubernetes.conf` and linked into `/etc/sysctl.d`. `prepare-kubernetes-node` does not set them. |
| containerd and runc are dynamically linked. A sysext does not refresh `/etc/ld.so.cache`. runc's libpathrs helper installs `libpathrs.so.0` as a symlink, and copying that path drops the symlink. Debian's 64-bit linker does not search `/usr/lib`. | The containerd sysext is built on the distro image (`ubuntu:24.04`, `rockylinux:9`). It ships a regular file at `/usr/lib/libpathrs.so.0` and links runc with `RUNPATH=/usr/lib`. |
| `kairos-init --version` accepts semver and rejects a git SHA. | `KAIROS_IMAGE_VERSION` defaults to `v0.1.0`. |

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
