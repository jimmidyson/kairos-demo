# CAPI Kairos FIPS Factory Implementation Plan

The factory is implemented. This plan's file map drifted (one `Dockerfile.cri`, CCM rendered by `scripts/render_ccm.py`, extension under `extension/cmd/inplace-extension`). The spec is the contract.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken ISO demo with a stepped factory that builds FIPS Kairos OS disks, runtime `cri`/`kubernetes` sysexts, FIPS kubeadm images, and a CAPX cluster that in-place upgrades v1.35→v1.36.

**Architecture:** Docker/buildx FIPS bases → kairos-operator `OSArtifact` cloud disks. AuroraBoot sysexts pulled at boot by `prepare-capi-node`. KIND runs operator + CAPI + CAPX + CAAPH + a Runtime Extension that SSHes `prepare-capi-node` then `kubeadm upgrade`.

**Tech Stack:** bash, Docker buildx, kairos-init, AuroraBoot container, kairos-operator, clusterctl, CAPX, CAAPH, Go (in-place extension + tests).

## Global Constraints

- CABPK only; no Kairos k8s provider; no OEM `kubeadm init`.
- `GOFIPS140=certified` (not `latest`); Go 1.25.10+ / 1.26.3+ / 1.27+ or pin `v1.0.0`.
- Kubernetes: `v1.35.8` and `v1.36.4` (override via env).
- OS: ubuntu-22.04, ubuntu-24.04, rocky-9. Arch: amd64, arm64.
- `cri` sysext per OS×arch (dynamic containerd). `kubernetes` sysext per ver×arch.
- Sysexts not baked into the disk. `--registry` is `${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX}`.
- Registry is existing Harbor; do not start a local registry.
- CAPX e2e: Ubuntu 24.04 amd64, 1 CP + 1 worker, create at v1.35, in-place to v1.36.
- arm64: build+push only.
- Scripts communicate; no e2e test harness.
- Cilium + Nutanix CCM via CAAPH only.

## File map

| Path | Responsibility |
|---|---|
| `versions.env` | Pinned component versions |
| `scripts/lib.sh` | env, logging, image names |
| `scripts/01-check-env.sh` … `10-destroy.sh` | one factory step each |
| `demo.sh` | run all or one step |
| `image/prepare-capi-node` | node-up / in-place sysext apply |
| `image/cloud-config.yaml` | OEM: users, sysext, no kubeadm |
| `image/Dockerfile.ubuntu` `image/Dockerfile.rocky` | FIPS Kairos bases |
| `sysexts/Dockerfile.containerd` `Dockerfile.runc` `Dockerfile.cniplugins` `Dockerfile.kubernetes` | component images for auroraboot |
| `k8s-images/build.sh` | FIPS kubeadm static-pod images + pause retag |
| `osartifact/cloud-image.yaml.tpl` | OSArtifact cloudImage |
| `capi/cluster.yaml.tpl` | CAPX cluster at OLD version |
| `capi/cilium.yaml` `capi/ccm.yaml` | CAAPH HelmChartProxy |
| `extension/` | CAPI in-place Runtime Extension |
| `tests/` | bash checks for lib + prepare-capi-node |

Delete: `terraform/`, `install-cloud-config.yaml`, `kubernetes-cloud-config.yaml`, `dockerfiles/Dockerfile.{base,bootstrap,final,containerd,runc,cniplugins,kubernetes}`, old `demo.sh` (replaced), old `cloud-config.yaml` (replaced by `image/cloud-config.yaml`).

---

### Task 1: versions + script lib + env check

**Files:** Create `versions.env`, `scripts/lib.sh`, `scripts/01-check-env.sh`, `tests/lib_test.sh`, `demo.sh`. Modify `devbox.json` (add `clusterctl`, `go`).

**Interfaces:**
- `require_env NAME` — exits 2, prints `missing env: NAME`
- `image_prefix` — `echo ${OCI_REGISTRY}/${OCI_REPOSITORY_PREFIX}`
- `base_image OS ARCH` — `${prefix}/base:${os}-${arch}`
- `cri_image OS ARCH` — `${prefix}/cri:${os}-${arch}`
- `kubernetes_image VER ARCH` — `${prefix}/kubernetes:${ver}-${arch}`
- `step_start NUM TITLE WHY TOUCH`
- `step_ok` / `step_fail`
- `next_step NUM`

- [ ] **Step 1: Write failing lib test** (`tests/lib_test.sh` sources `scripts/lib.sh`, asserts `require_env` fails with variable name, `image_prefix` concatenates).
- [ ] **Step 2: Run it — expect FAIL** (lib.sh missing).
- [ ] **Step 3: Implement `versions.env`, `scripts/lib.sh`, `scripts/01-check-env.sh`, `demo.sh`.**
- [ ] **Step 4: Run `tests/lib_test.sh` — expect PASS.**
- [ ] **Step 5: Commit.**

### Task 2: prepare-capi-node

**Files:** Create `image/prepare-capi-node`, `tests/prepare-capi-node_test.sh`.

**Interfaces:**
- `detect_os <os-release-text>` → `ubuntu-22.04` \| `ubuntu-24.04` \| `rocky-9`
- `detect_arch <uname-m>` → `amd64` \| `arm64`
- `cri_ref REGISTRY OS ARCH`
- `kubernetes_ref REGISTRY VER ARCH`
- `set_file_contents REGISTRY OS ARCH VER` (sidecar `/var/lib/extensions/capi-node.set`)
- `already_applied SETFILE REGISTRY OS ARCH VER` → 0 if no-op
- CLI: `prepare-capi-node --registry R --kubernetes-version V [--os --arch]`

Test with `PREPARE_CAPI_NODE_ROOT` pointing at a temp fake root (no real systemd).

- [ ] **Step 1: Failing tests** for detect, refs, missing `--registry`, no-op when set file matches, apply writes set file.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement script.** Dry-run/test mode skips crane/systemctl when root is fake; still writes set file and extension paths.
- [ ] **Step 4: Tests PASS.**
- [ ] **Step 5: Commit.**

### Task 3: FIPS bases + OEM cloud-config

**Files:** Create `image/Dockerfile.ubuntu`, `image/Dockerfile.rocky`, `image/cloud-config.yaml`, `image/sysext-hierarchies.conf`. Delete old `dockerfiles/Dockerfile.base`.

Ubuntu Dockerfile: kairos-init, Pro attach from secret, enable FIPS/USG, install crane + prepare-capi-node, enable systemd-sysext. Rocky: dnf + fips-mode-setup. Copy `prepare-capi-node` to `/usr/sbin/prepare-capi-node`.

- [ ] **Step 1: Dockerfiles + cloud-config with no kubeadm init** (grep test in `tests/image_contract_test.sh`: cloud-config must not contain `kubeadm init`).
- [ ] **Step 2: Run contract test FAIL then add files PASS.**
- [ ] **Step 3: `scripts/02-build-bases.sh`** loops OS×arch, buildx push.
- [ ] **Step 4: Commit.**

### Task 4: sysext component images + auroraboot

**Files:** `sysexts/Dockerfile.containerd` (dynamic, FROM the *OS* base for glibc), `sysexts/Dockerfile.runc`, `sysexts/Dockerfile.cniplugins`, `sysexts/Dockerfile.kubernetes` (`GOFIPS140=certified`), `scripts/03-build-sysexts.sh`.

containerd image `FROM` `${base}` so it links that glibc. kubernetes image `FROM scratch` after a Go builder with `GOFIPS140=certified`.

- [ ] **Step 1: `tests/sysext_names_test.sh`** asserts `cri_image` / `kubernetes_image` naming.
- [ ] **Step 2: Dockerfiles + build script** (auroraboot via `quay.io/kairos/auroraboot`, output raw, wrap in scratch image with `/extension.raw`).
- [ ] **Step 3: Commit.**

### Task 5: FIPS kubeadm images

**Files:** `k8s-images/build.sh`, `scripts/04-build-k8s-images.sh`.

Build kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy, etcd, coredns with `GOFIPS140=certified`. Retag pause from registry.k8s.io. Push to `${image_prefix}/$name:$ver`. Both versions, both arches.

- [ ] Implement + `tests/k8s_images_list_test.sh` (expected image names).
- [ ] Commit.

### Task 6: OSArtifact + KIND operator

**Files:** `osartifact/cloud-image.yaml.tpl`, `scripts/05-osartifact.sh`. Cloud-config secret without kubeadm. Wait Ready. Download Ubuntu 24.04 amd64 disk only.

- [ ] Implement. Commit.

### Task 7: Prism upload + clusterctl + CAAPH cluster

**Files:** `scripts/06-upload-prism.sh`, `scripts/07-capi-init.sh`, `capi/cluster.yaml.tpl`, `capi/cilium.yaml`, `capi/ccm.yaml`, `scripts/08-create-cluster.sh`.

Upload via Prism API or `nutanix` CLI if present; else `curl` to images API using `NUTANIX_*`. clusterctl init `-i nutanix` plus CAAPH. Cluster at `KUBERNETES_VERSION_OLD`, `preKubeadmCommands: prepare-capi-node --registry $(image_prefix) --kubernetes-version $ver`, `imageRepository: $(image_prefix)`.

- [ ] Implement. Commit.

### Task 8: In-place extension + bump step

**Files:** `extension/go.mod`, `extension/canupdate.go`, `extension/canupdate_test.go`, `extension/main.go`, `extension/Dockerfile`, `scripts/09-inplace-upgrade.sh`.

`CanUpdateInPlace(currentImage, desiredImage, currentVer, desiredVer) bool` — true iff images equal and versions differ.

`UpdateMachine` SSHes `prepare-capi-node` then `kubeadm upgrade apply` / `kubeadm upgrade node`.

Step 9 patches KCP+MD version to NEW, waits Ready, prints Machine names (must be unchanged).

- [ ] TDD canupdate. Implement server. Commit.

### Task 9: destroy, README, delete dead demo

**Files:** `scripts/10-destroy.sh`, rewrite `README.md`. Delete terraform, old dockerfiles, `install-cloud-config.yaml`, `kubernetes-cloud-config.yaml`, leftover ISO cloud-config.

- [ ] Implement. `devbox run -- tests/*.sh` all pass.
- [ ] Commit.

### Spec coverage

| Spec item | Task |
|---|---|
| FIPS bases 3×2 | 3 |
| cri/k8s sysexts | 4 |
| FIPS kubeadm images | 5 |
| OSArtifact VM disks | 6 |
| Harbor configurable | 1 |
| prepare-capi-node + re-run | 2 |
| CAPX cluster v1.35 + CAAPH | 7 |
| In-place v1.36 | 8 |
| Stepped scripts | 1, 9 |
| arm64 build-only | 3–5 loops include arm64; 6–8 amd64 ubuntu 24.04 only |
| Delete old ISO/tofu path | 9 |
| Unit checks | 1, 2, 8 |
