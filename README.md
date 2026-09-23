# Kairos CAPI FIPS factory

Builds hardened Kairos OS disks (Ubuntu 22.04, 24.04, Rocky 9 × amd64/arm64), runtime **sysexts** for CRI and Kubernetes, and FIPS-rebuilt kubeadm images. A stepped script stands up a CAPX cluster on Nutanix (KIND management plane) and in-place upgrades v1.35 → v1.36.

**OS hardening (best-effort in an image build):**

| OS | FIPS | CIS L1 server | DISA STIG |
|---|---|---|---|
| Ubuntu 22.04 / 24.04 | Ubuntu Pro `fips-updates` (or `fips`) | `usg fix cis_level1_server` | `usg fix disa_stig` if that USG release has the profile |
| Rocky 9 | `fips-mode-setup --enable` | OpenSCAP `cis_server_l1` on `ssg-rl9-ds.xml` | OpenSCAP `stig` on the same datastream |
| RHEL 9 | same as Rocky | same, datastream `ssg-rhel9-ds.xml` | same |

RHEL is not in the default `OSES` list (needs a Red Hat registry pull). Set `BASE_IMAGE` to a RHEL 9 image and use `image/Dockerfile.rocky` + `harden-el.sh` if you have one. CIS then STIG (STIG wins conflicts). Many SCAP/USG rules need a real boot and will report findings during `docker build`; that does not fail the build on Rocky. Ubuntu CIS fix is required; STIG is skipped if USG has no `disa_stig` profile.

Design: [`docs/superpowers/specs/2026-08-25-capi-kairos-fips-design.md`](docs/superpowers/specs/2026-08-25-capi-kairos-fips-design.md)

## What this is not

Not a Kairos Kubernetes provider. Not first-boot `kubeadm init`. Bootstrap is **CABPK** only. Cilium and Nutanix CCM are **CAAPH**, not baked into the image. arm64 is build-and-push only (no CAPX).

## Prerequisites

```bash
devbox shell
```

Need Docker buildx, a Harbor project you can push to (e.g. `harbor.eng.nutanix.com`), Ubuntu Pro token, and Prism credentials.

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
export CONTROL_PLANE_ENDPOINT_IP=...   # unused VIP/IP for the workload API
```

Optional: `KAIROS_IMAGE_VERSION` (default `v0.1.0`, must be semver — kairos-init rejects git SHAs), `KUBERNETES_VERSION_OLD` (default `v1.35.8`), `KUBERNETES_VERSION_NEW` (default `v1.36.4`), `NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME`, `IMAGE_SOURCE_URI` (HTTP URL Prism can pull the cloud disk from).

## Run

```bash
./demo.sh          # steps 1–10
./demo.sh 1        # env + Harbor login
./demo.sh 8        # create cluster only (after 1–7)
```

| Step | Script | Does |
|---:|---|---|
| 1 | `scripts/01-check-env.sh` | Required env, `docker login` |
| 2 | `scripts/02-build-bases.sh` | FIPS Kairos OCI bases |
| 3 | `scripts/03-build-sysexts.sh` | `cri` + `kubernetes` sysexts via AuroraBoot |
| 4 | `scripts/04-build-k8s-images.sh` | FIPS kubeadm images + pause retag |
| 5 | `scripts/05-osartifact.sh` | KIND, kairos-operator, cloud disks |
| 6 | `scripts/06-upload-prism.sh` | Prism image for CAPX |
| 7 | `scripts/07-capi-init.sh` | clusterctl CAPX + CAAPH |
| 8 | `scripts/08-create-cluster.sh` | 1 CP + 1 worker at v1.35, Cilium, CCM |
| 9 | `scripts/09-inplace-upgrade.sh` | Same Machines, v1.36 |
| 10 | `scripts/10-destroy.sh` | Delete cluster (`DESTROY_KIND=1` also drops KIND) |

`prepare-capi-node --registry $OCI_REGISTRY/$OCI_REPOSITORY_PREFIX --kubernetes-version v1.35.8` is the only node-local installer. CAPI `preKubeadmCommands` runs it on first boot; step 9 re-runs it over SSH for in-place upgrade.

## Checks (not a cluster e2e)

```bash
bash tests/lib_test.sh
bash tests/prepare-capi-node_test.sh
bash tests/image_contract_test.sh
bash tests/sysext_names_test.sh
bash tests/k8s_images_list_test.sh
( cd extension && go test ./... )
```

## Image names

Prefix = `$OCI_REGISTRY/$OCI_REPOSITORY_PREFIX`

- `base:ubuntu-24.04-amd64` (and the other OS/arch tags)
- `cri:ubuntu-24.04-amd64`
- `kubernetes:v1.36.4-amd64`
- `kube-apiserver:v1.36.4` (and controller-manager, scheduler, proxy, etcd, coredns, pause)
