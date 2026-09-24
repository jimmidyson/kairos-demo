# CAPI kubeadm Kairos FIPS image factory

**Date:** 2026-08-25
**Status:** implemented (see Implementation notes)

## Problem

This repo is a half-migrated Kairos demo. It does not produce a disk image that Cluster API’s kubeadm bootstrap provider (CABPK) can use. We need a factory that emits FIPS-enabled Kairos OS images for Ubuntu 22.04, Ubuntu 24.04, and Rocky 9, plus versioned node-component sysexts, plus FIPS-rebuilt kubeadm container images — all consumable by CAPX (Cluster API Provider Nutanix) on a KIND management cluster.

## Goals

- Generic CABPK only. No Kairos Kubernetes provider. No first-boot `kubeadm init` in OEM cloud-config.
- FIPS on the OS **and** on every Go node/control-plane component we build, using the Go standard library CMVP-certified module (`GOFIPS140=certified`).
- Kubernetes components as runtime sysexts (not baked into the OS disk).
- VM disks via kairos-operator `OSArtifact` (`cloudImage`).
- Sysexts via AuroraBoot.
- Prove three OSes and two arches. CAPX e2e is one combo. arm64 is build-only.
- In-place Kubernetes upgrade on the same Machines via CAPI v1.12 Runtime SDK hooks.
- Operator UX is stepped shell scripts, not a test harness.

## Non-goals (v1)

- Air-gapped operation (nodes must reach the configured registry).
- FIPS rebuilds of Cilium or Nutanix CCM images.
- Secure Boot key ceremony beyond whatever AuroraBoot needs to emit a sysext.
- Automated e2e assertions / CI grid.
- arm64 boot or CAPX on ARM AHV.
- Local registry process. We push to an existing registry.

## Success

A human can run `./demo.sh` (or the individual step scripts) and see:

1. Six FIPS Kairos cloud disks built (3 OS × 2 arch) and pushed where relevant.
2. Six `cri` sysexts and four `kubernetes` sysexts pushed.
3. FIPS kubeadm images for v1.35.x and v1.36.x pushed.
4. Ubuntu 24.04 amd64 disk uploaded to Prism.
5. KIND hosting CAPI + CABPK + CAPX + CAAPH + our in-place extension.
6. One CAPX cluster: 1 control plane + 1 worker, **created at v1.35**, Cilium + Nutanix CCM via CAAPH, both nodes `Ready`.
7. In-place bump to v1.36: same Machine objects, kubelet/control-plane at v1.36, nodes still `Ready`.

Stopping after any step prints the next command.

## Constraints (verbatim)

- CAPI contract: CABPK. CAPI cloud-init is the only bootstrap.
- FIPS Go: `GOFIPS140=certified` at build (alias for the latest CMVP-certified Go Cryptographic Module, currently v1.0.0 / cert #5247). Do not use `GOFIPS140=latest`. Build-time flag enables FIPS mode; do not rely on `GODEBUG=fips140=on`.
- Go toolchain: 1.25.10+, 1.26.3+, or 1.27+ so the `certified` alias exists; otherwise pin `GOFIPS140=v1.0.0`.
- Kubernetes lines: v1.35.x and v1.36.x (patch latest at build time).
- OSes: Ubuntu 22.04, Ubuntu 24.04, Rocky 9.
- Arches: amd64 and arm64. CAPX/AHV e2e is amd64 only. arm64 is build+push only.
- containerd is dynamically linked → `cri` sysext is per OS × arch.
- `kubernetes` sysext is static Go → per version × arch, shared across OSes.
- Sysexts are **not** baked into the OS disk.
- VM images: kairos-operator `OSArtifact` `cloudImage` (osbuilder successor).
- Sysext generation: `auroraboot sysext`.
- Registry: configurable (`OCI_REGISTRY` + `OCI_REPOSITORY_PREFIX` + credentials). Operator uses `harbor.eng.nutanix.com`.
- Infra: CAPX (`cluster-api-provider-nutanix`), `clusterctl init -i nutanix`.
- Management: KIND.
- Addons: Cilium and Nutanix CCM via CAAPH (HelmChartProxy). No other install path.
- Cluster shape: 1 CP + 1 worker.
- Scripted demo, not a proper e2e suite. Steps runnable together or alone.
- In-place upgrade: CAPI v1.12 Runtime SDK (`CanUpdateMachine`, `CanUpdateMachineSet`, `UpdateMachine`). No home-grown loop.

## Architecture

```text
docker/buildx ──► FIPS Kairos OCI bases (3 OS × 2 arch)
                         │
                         ▼
              kairos-operator OSArtifact cloudImage
                         │
                         ▼
              preinstalled raw/qcow2 (no k8s/cri)
                         │
                         ▼  amd64 Ubuntu 24.04 only
                    Prism image
                         │
auroraboot sysext ──► Harbor: cri-* and kubernetes-*
GOFIPS140=certified ──► Harbor: kube-apiserver, …, etcd, coredns; pause retagged

KIND: CAPI + CABPK + CAPX + CAAPH + inplace-extension
  └─ CAPX VMs boot OS disk
       preKubeadmCommands: prepare-capi-node --registry … --kubernetes-version v1.35.x
       CABPK: kubeadm init/join, imageRepository=Harbor
       CAAPH: Cilium + Nutanix CCM
       version bump → Runtime Extension SSH → prepare-capi-node + kubeadm upgrade
```

### Artifact matrix

| Artifact | Dimensions | Count |
|---|---|---|
| FIPS OS cloud disk | OS × arch | 6 |
| `cri` sysext | OS × arch | 6 |
| `kubernetes` sysext | k8s version × arch | 4 |
| FIPS kubeadm images | k8s version × arch | 2 versions × 2 arch (image list per kubeadm) |

Harbor names (prefix = `${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX}`):

- bases: `${prefix}/base:${os}-${arch}` (os = `ubuntu-22.04` \| `ubuntu-24.04` \| `rocky-9`)
- cri sysext: `${prefix}/cri:${os}-${arch}`
- kubernetes sysext: `${prefix}/kubernetes:${kubernetes-version}-${arch}` (version includes `v`, e.g. `v1.36.4`)
- kubeadm images: `${prefix}/kube-apiserver:${ver}`, etc., matching `kubeadm config images list` for that version so kubeadm does not invent paths. CoreDNS uses the path kubeadm expects for a custom `imageRepository` (no extra `coredns/` infix unless kubeadm’s list says so). pause is retagged upstream.

### Base image

Per OS × arch, Docker/buildx + kairos-init. Docker 24.0.6 / BuildKit v0.11.6 commits a large bind-mounted `RUN` as whiteouts of `/`. Docker 29.8.1 / BuildKit v0.33.0 does not. The minimum in between is unknown; the check uses that known-good pair and `KAIROS_SKIP_DOCKER_CHECK=1` skips it.

- Ubuntu: Ubuntu Pro FIPS packages / USG as required for that release. `UBUNTU_PRO_TOKEN` required for Ubuntu builds.
- Rocky 9: `fips-mode-setup --enable` (or distro-equivalent) so `/proc/sys/crypto/fips_enabled` is 1 after boot.
- `systemd-sysext` enabled; `/var/lib/extensions` writable and persistent.
- `/etc` and `/var` persist so CABPK can write `/etc/kubernetes` and `/var/lib/kubelet`.
- `prepare-capi-node` installed on the base (not a sysext).
- Debug user + SSH authorized key from env (`NUTANIX_SSH_AUTHORIZED_KEY`).
- No kubeadm, kubelet, containerd, or first-boot `kubeadm init`.

### Sysexts

**`cri`:** dynamically linked containerd (that OS’s glibc), runc, CNI plugins, systemd units under `/usr/lib/systemd`. Built `GOFIPS140=certified` for Go bits.

**`kubernetes`:** kubeadm, kubelet, kubectl from the Kubernetes tree, `GOFIPS140=certified`. kubelet drop-in so it uses containerd. Same artifact on all three OSes.

Built with `auroraboot sysext` from component OCI images.

### `prepare-capi-node`

Applies the **known set** (`cri` + `kubernetes`) to make the node CABPK-ready. Not a generic OCI applier.

```text
prepare-capi-node --registry REGISTRY --kubernetes-version vX.Y.Z
```

- Detects OS from `/etc/os-release` (`ubuntu-22.04`, `ubuntu-24.04`, `rocky-9`) and arch from `uname -m` (`amd64` / `arm64`).
- Optional overrides: `--os`, `--arch` (debug only).
- Pulls `${registry}/${prefix?}` — registry argument is the full image-repository prefix used by kubeadm (`${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX}`).
- Installs under `/var/lib/extensions`, `systemd-sysext refresh`.
- Enables/starts containerd and kubelet.
- Sets containerd `sandbox_image` to `${registry}/pause:<tag>` for that Kubernetes version.
- Exit non-zero on any failure (CAPI Machine fails).

**Re-run / in-place:**

1. If live extension IDs already match the requested set → no-op (do not bounce services).
2. Else pull new sysexts beside the live ones.
3. Stop kubelet; stop containerd only if `cri` is changing.
4. Atomically replace `/var/lib/extensions`, `systemd-sysext refresh`.
5. Start containerd if needed, then kubelet.

Does **not** run `kubeadm upgrade`, drain the node, or change the OS. That is the Runtime Extension’s job.

CAPI first boot: `preKubeadmCommands` is exactly:

```text
prepare-capi-node --registry ${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX} --kubernetes-version ${KUBERNETES_VERSION}
```

### FIPS kubeadm images

Rebuild with `GOFIPS140=certified` and push to the configured registry:

| Image | Source |
|---|---|
| kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy | Kubernetes tree |
| etcd | etcd version kubeadm pins for that k8s |
| coredns | CoreDNS version kubeadm pins |
| pause | retag upstream (C, not Go) |

`KubeadmConfig.clusterConfiguration.imageRepository` = `${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX}`.

Cilium and Nutanix CCM stay upstream via CAAPH.

**Known ceiling:** the cluster is not a FIPS-validated *system*. Node agents and kubeadm static pods we build are FIPS-mode Go; Cilium/CCM/pause are not.

### VM disks

kairos-operator on KIND. One `OSArtifact` per OS × arch, `spec.image.ref` = base OCI image, `spec.artifacts.cloudImage: true`. Output is a preinstalled raw disk named after the OSArtifact (`cloud-<os>-<arch>.raw`). Kairos first-boot install happens at image build, not at CAPX VM boot. Sysexts are not in the disk.

Upload **only** Ubuntu 24.04 amd64 to Prism for the scripted cluster. Other amd64 disks may be uploaded if a step is run with overrides; arm64 disks are not uploaded.

### E2E (scripted, not a test suite)

KIND management cluster:

1. kairos-operator (image builds), then CAPI stack (can share KIND; serialize if needed).
2. `clusterctl init` with CABPK + CAPX + CAAPH.
3. Deploy our in-place Runtime Extension + `ExtensionConfig`.
4. Prism creds from `NUTANIX_*` env (same names as CAPX getting-started).
5. Cluster at **v1.35.x**, 1 CP + 1 worker, same Ubuntu 24.04 amd64 `NutanixMachineTemplate`.
6. CAAPH HelmChartProxy: Nutanix CCM, Cilium.
7. Wait until both nodes `Ready`.
8. Bump KCP + MachineDeployment to v1.36.x. Extension performs in-place update. Same Machine names. Wait `Ready`.
9. Destroy: delete Cluster, then the Nutanix image we created. KIND tear-down optional.

### In-place Runtime Extension

CAPI v1.12 hooks:

- `CanUpdateMachine` / `CanUpdateMachineSet`: allow in-place iff the Nutanix disk image name is unchanged and the diff is Kubernetes version (and matching image tags). Any other infra change → CAPI rolls a new VM.
- `UpdateMachine`: SSH with the key already on the Machine; run `prepare-capi-node --registry … --kubernetes-version $desired`; then `kubeadm upgrade apply` on a control-plane node or `kubeadm upgrade node` on a worker. Non-zero fails the hook.

No second installer. Feature gate `InPlaceUpdates=true` on CAPI controllers as required by the installed CAPI version.

### Scripts

Replace `demo.sh` with:

| Path | Role |
|---|---|
| `scripts/lib.sh` | env checks, Harbor login, colored step output |
| `scripts/01-check-env.sh` … `scripts/10-destroy.sh` | one concern each |
| `demo.sh` | runs 01–10 in order, or `./demo.sh 8` for one step |

Each step prints: **what**, **why**, **what it will touch**, live logs, **ok/fail**, and the next command on stop. `set -euo pipefail`. Idempotent where cheap (KIND exists, image already in Harbor, Cluster exists).

Step list:

1. Check env, Harbor login
2. Build FIPS bases (3×2) → registry
3. Build `cri` + `kubernetes` sysexts → registry
4. Build FIPS kubeadm images (1.35 + 1.36, both arches) → registry
5. KIND + kairos-operator; OSArtifact cloud disks; fetch Ubuntu 24.04 amd64 disk
6. Upload that disk to Prism
7. `clusterctl init` + Runtime Extension
8. Create cluster at v1.35 + CAAPH addons; wait Ready
9. In-place bump to v1.36; wait Ready
10. Destroy cluster + Nutanix image (KIND optional)

### Environment

Required:

- `OCI_REGISTRY` (example: `harbor.eng.nutanix.com`)
- `OCI_REPOSITORY_PREFIX`
- `OCI_REGISTRY_USERNAME`, `OCI_REGISTRY_PASSWORD`
- `UBUNTU_PRO_TOKEN` (Ubuntu base builds)
- `NUTANIX_ENDPOINT`, `NUTANIX_USER`, `NUTANIX_PASSWORD`
- `NUTANIX_PRISM_ELEMENT_CLUSTER_NAME`, `NUTANIX_SUBNET_NAME`
- `NUTANIX_SSH_AUTHORIZED_KEY`
- `CONTROL_PLANE_ENDPOINT_IP` (CAPX)

Optional:

- `KUBERNETES_VERSION_OLD` default latest v1.35.x
- `KUBERNETES_VERSION_NEW` default latest v1.36.x
- `KAIROS_KIND_CLUSTER_NAME` default `kairos-demo`

### Failure handling

Fatal, with a pointer to the object/log:

- missing required env
- Harbor auth / push / pull from AHV
- OSArtifact not Ready
- `prepare-capi-node` non-zero
- kubeadm missing after prepare
- OS FIPS not enabled on the node
- `CanUpdateMachine` false when we expected in-place (unexpected rollout)
- hook SSH or `kubeadm upgrade` fail
- nodes not Ready after timeout

### Repo cleanup

Delete or stop treating as the happy path:

- tofu Nutanix ISO VM demo
- empty `install-cloud-config.yaml`
- `kubernetes-cloud-config.yaml` first-boot `kubeadm init`
- unused component Dockerfiles that are not the new FIPS/sysext builds
- README that documents `docker buildx` + ISO + Helm osbuilder

Replace README with the script contract, env vars, artifact names, and this spec pointer.

## Testing

No cluster e2e suite. Checks that must exist:

- `prepare-capi-node` unit/self-test: OS/arch detect, ref construction, no-op when already applied, fail when registry unset.
- Runtime Extension unit tests: `CanUpdate` true only for version-only diffs; false when image name changes.
- Script lib: missing-env fails with the variable name.

Human-run `./demo.sh` is the integration proof.

## Implementation notes

- On macOS, `KAIROS_BUILDER=auto` and `KAIROS_MGMT=auto` select Apple `container` for image builds and `container k8s` for the management cluster when that CLI is installed. `KAIROS_BUILDER=docker` and `KAIROS_MGMT=kind` keep Docker buildx and KIND. Both builders push the sysext rootfs and run AuroraBoot without a Docker socket, so that container cannot drive the host daemon. AuroraBoot pulls the rootfs itself. Multi-arch indexes are `crane index append`.
- Core, kubeadm bootstrap, and kubeadm control plane are `CAPI_VERSION` (default `v1.13.6`). The Runtime Extension module is the same release. CAPX and CAAPH stay on the versions clusterctl selects for that contract.
- Kairos operator is pinned to `v0.2.2` (`spec.image.ref`, `spec.artifacts.cloudImage`, `spec.artifacts.cloudConfigRef`). Step 5 retargets the Deployment image because that tag's kustomize still names the previous release. `config/nginx` is applied separately. The Ubuntu 24.04 amd64 disk is downloaded with `kubectl port-forward`, and a missing file fails step 5.
- FIPS and the CIS/STIG scripts run after `kairos-init -s install` and before `-s init`. `fips=1` is written to `/etc/default/grub` so the UKI build can see it. Those profiles remove `rsync` and mask `systemd-timesyncd`. `rsync` is installed again before `-s init` because dracut will not build the UKI without it. `chrony` and `systemd-timesyncd` cannot be installed together. timesyncd is installed for `-s init`, which enables it. `chrony` is removed without purge so its STIG config remains, then installed again. timesyncd is purged and masked. The Ubuntu Pro token is removed from the image after attach.
- The `cri` sysext compiles on the distro image that matches the OS (`distro_image`), so it links that glibc without using the Kairos root as a build environment. containerd, runc, and the CNI plugins are built with `GOFIPS140=certified`.
- Static pod image names and tags are whatever `kubeadm config images list --image-repository` prints. Each tag is a multi-arch manifest list. The kubernetes sysext carries `/usr/lib/kairos/pause-tag`; `prepare-capi-node` applies it as containerd 2 `plugins.'io.containerd.cri.v1.images'.pinned_images.sandbox` after `systemd-sysext refresh`, and it pulls sysexts before stopping kubelet.
- Step 7 deploys the Runtime Extension (`CanUpdateMachine`, `CanUpdateMachineSet`, `UpdateMachine`) and turns on `InPlaceUpdates`. `CanUpdate*` returns a JSON patch only when the Nutanix image identity is unchanged and every spec diff is the Kubernetes version string. Step 9 patches the control plane first, waits, then patches workers. It does not SSH itself.
- KubeadmControlPlane `maxSurge` is 0. MachineDeployment `maxSurge` is 0 and `maxUnavailable` is 1 (v1beta2 field is `spec.rollout.strategy`).
- `imageRepository` is set on `kubeadmConfigSpec.clusterConfiguration`. Prism calls use a curl config file. TLS is verified unless `NUTANIX_INSECURE=1`; `NUTANIX_CA_FILE` is the Prism CA. Step 6 fails until the image is `COMPLETE`. Step 10 deletes it.
- Nutanix CCM is a second HelmChartProxy rendered at step 8 with Prism credentials under `config.prismCentral`. The chart repo is `NUTANIX_CCM_REPO` (default `https://nutanix-cloud-native.github.io/cloud-provider-nutanix`). `https://nutanix.github.io/helm-releases` is the NCM product index, not this chart.

## Open ceilings (deliberate)

- First boot and upgrades need Harbor reachability from AHV.
- pause, Cilium, CCM are not FIPS-rebuilt.
- arm64 is compile/push only.
- In-place exec is SSH, not guest-tools.
