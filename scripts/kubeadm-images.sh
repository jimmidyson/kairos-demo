#!/usr/bin/env bash
# kubeadm config images list is the source of truth for names and tags.
# Source this; it does not change shell options.

kubeadm_host_os_arch() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
  esac
  printf '%s %s\n' "${os}" "${arch}"
}

kubeadm_bin() {
  local ver="$1" os arch dest
  # shellcheck disable=SC2162
  read -r os arch <<<"$(kubeadm_host_os_arch)"
  dest="${FACTORY_ROOT}/build/kubeadm-${ver}-${os}-${arch}"
  if [[ ! -x "${dest}" ]]; then
    mkdir -p "${FACTORY_ROOT}/build"
    curl -fsSL "https://dl.k8s.io/release/${ver}/bin/${os}/${arch}/kubeadm" -o "${dest}"
    chmod +x "${dest}"
  fi
  printf '%s\n' "${dest}"
}

kubeadm_image_list() {
  local ver="$1" prefix="$2" bin
  bin="$(kubeadm_bin "${ver}")"
  "${bin}" config images list --kubernetes-version "${ver}" --image-repository "${prefix}"
}

# stdin: kubeadm config images list lines. $1 is the image repository prefix.
# stdout: name<TAB>tag (name may contain slashes, e.g. coredns/coredns).
parse_image_list() {
  local prefix="$1" line rest name tag
  prefix="${prefix%/}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    rest="${line#"${prefix}/"}"
    if [[ "${rest}" == "${line}" ]]; then
      printf 'image %s is outside prefix %s\n' "${line}" "${prefix}" >&2
      return 1
    fi
    name="${rest%%:*}"
    tag="${rest##*:}"
    printf '%s\t%s\n' "${name}" "${tag}"
  done
}

pause_tag_from_list() {
  local name tag
  while IFS=$'\t' read -r name tag || [[ -n "${name}" ]]; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == "pause" || "${name}" == */pause ]]; then
      printf '%s\n' "${tag}"
      return 0
    fi
  done
  return 1
}
