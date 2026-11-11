# shellcheck shell=bash
# APT_FRESH is read by apt_ensure in lib/system/common.sh.
# shellcheck disable=SC2034
#
# The system install steps. Each one checks before it writes, so it is safe to
# run on a fresh image layer and on a VM that already has everything.
#
# Callers:
#   Dockerfile               through lib/system/install.sh, one RUN per step,
#                            so a step keeps its own layer and cache
#   scripts/install-native.sh sources this file after its clone
#
# A change to what a devaloy box carries goes here, or in config/apt/. Edit
# the Dockerfile or install-native.sh only for work that one path alone does:
# the image's ENTRYPOINT and HEALTHCHECK, or the VM's env file, systemd units,
# Docker address ranges and firewall.
#
# Needs lib/system/common.sh sourced first.

# The two directories the CLI lands in, the same on both paths.
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/bin}"
SYS_LIB_DIR="${SYS_LIB_DIR:-/usr/local/lib/devaloy}"

# zsh-completions has no package in noble or trixie (only autosuggestions and
# syntax-highlighting do), so it comes from a pinned release tarball. It is a
# directory of completion functions, not something to source: zshrc puts src/
# on fpath ahead of compinit.
ZSH_COMPLETIONS_VERSION="${ZSH_COMPLETIONS_VERSION:-0.36.0}"

# The five old command names. Symlinks rather than wrapper scripts: `devaloy`
# reads its own basename and infers the verb, so there is nothing to keep in
# sync.
SYS_OLD_VERBS=(devaloy-update devaloy-disk devaloy-ram devaloy-prune devaloy-nvim-sync)

# --- apt repos -----------------------------------------------------------------

# tailscaled runs on the box itself, in the container and on a VM alike.
# Tailscale SSH terminates the connection wherever tailscaled runs and spawns
# the shell there, so a sidecar would drop you into the sidecar's filesystem.
# See tailscale/tailscale#5215.
sys_tailscale_repo() {
  sys_distro
  local base="https://pkgs.tailscale.com/stable/${OS_ID}/${OS_CODENAME}"
  fetch_to "${base}.noarmor.gpg" \
    "${SYS_ROOT}/usr/share/keyrings/tailscale-archive-keyring.gpg" 644
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0
  fetch_to "${base}.tailscale-keyring.list" \
    "${SYS_ROOT}/etc/apt/sources.list.d/tailscale.list" 644
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0
  sys_ok "Tailscale apt repo (${OS_ID} ${OS_CODENAME})"
}

# Docker's apt repo, for WITH_DOCKER. The repo stays on the box after the
# install, so `apt-get upgrade` moves Docker the way it moves tailscale. The
# architecture comes from dpkg, so this resolves on an ARM host too.
sys_docker_repo() {
  sys_distro
  fetch_to "https://download.docker.com/linux/${OS_ID}/gpg" \
    "${SYS_ROOT}/usr/share/keyrings/docker.asc" 644
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0
  put_content "${SYS_ROOT}/etc/apt/sources.list.d/docker.list" 644 < <(
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "${OS_ID}" "${OS_CODENAME}")
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0
  sys_ok "Docker apt repo (${OS_ID} ${OS_CODENAME})"
}

# --- packages ------------------------------------------------------------------

# A stamp file records the version, so a re-run with the same pin downloads
# nothing, and a new pin replaces the whole directory.
sys_zsh_completions() {
  local dest="${SYS_ROOT}/usr/share/zsh-completions" stamp tmp
  stamp="${dest}/.devaloy-version"
  if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${ZSH_COMPLETIONS_VERSION}" ]; then
    sys_ok "zsh-completions ${ZSH_COMPLETIONS_VERSION} present"
    return 0
  fi
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 \
    "https://github.com/zsh-users/zsh-completions/archive/refs/tags/${ZSH_COMPLETIONS_VERSION}.tar.gz" |
    tar -xz -C "${tmp}" --strip-components=1
  printf '%s\n' "${ZSH_COMPLETIONS_VERSION}" > "${tmp}/.devaloy-version"
  rm -rf "${dest}"
  mkdir -p "$(dirname "${dest}")"
  mv "${tmp}" "${dest}"
  chmod 755 "${dest}"
  sys_ok "zsh-completions ${ZSH_COMPLETIONS_VERSION} installed"
}

# config/apt/packages.txt: one package per line, a comment on each one that
# needs a reason. The list needs the Tailscale repo in place first, unless the
# caller leaves tailscale out.
#
# Every name after REPO_DIR is left out of the list. An Upstash Box passes
# tailscale when WITH_TAILSCALE is off: Tailscale is optional there, and the
# box has no Tailscale repo until the key turns it on. The image and the
# native installer pass nothing, so they install the whole list.
sys_base_packages() { # sys_base_packages REPO_DIR [SKIP...]
  local pkgs repo="$1"
  shift
  mapfile -t pkgs < <(pkg_list "${repo}/config/apt/packages.txt" | pkg_skip "$@")
  [ "${#pkgs[@]}" -gt 0 ] || sys_die "config/apt/packages.txt is empty or missing."
  apt_ensure "${pkgs[@]}"
  # Ubuntu and Debian ship bat as `batcat` (a name clash with bacula-console)
  # and fd as `fdfind` (a clash with fdclone). Link the short names in
  # /usr/bin, not /usr/local/bin: link-shims owns the latter and overwrites a
  # symlink it finds there.
  [ -e /usr/bin/bat ] || ln -s /usr/bin/batcat /usr/bin/bat
  [ -e /usr/bin/fd ] || ln -s /usr/bin/fdfind /usr/bin/fd
  sys_ok "base packages present (${#pkgs[@]} listed)"
}

# WITH_BROWSER. The system half of playwright-cli: the shared libraries a
# headless Chromium needs, plus ffmpeg. The browser itself is a per-release
# download into ~/.cache/ms-playwright, which bootstrap-toolchain.sh fetches.
#
# The list carries the t64 names (libasound2t64 and three more), which is what
# noble and trixie call those libraries since the 64-bit time_t move. Debian 12
# bookworm, the base of an Upstash Box, predates the move and ships them under
# the old names, so on bookworm the suffix is dropped. Every other name in the
# list is the same on all three releases.
sys_browser_packages() { # sys_browser_packages REPO_DIR
  local pkgs
  sys_distro
  if [ "${OS_CODENAME}" = bookworm ]; then
    mapfile -t pkgs < <(pkg_list "$1/config/apt/browser.txt" | sed 's/t64$//')
  else
    mapfile -t pkgs < <(pkg_list "$1/config/apt/browser.txt")
  fi
  [ "${#pkgs[@]}" -gt 0 ] || sys_die "config/apt/browser.txt is empty or missing."
  apt_ensure "${pkgs[@]}"
  sys_ok "browser libraries present (the bootstrap fetches playwright-cli and Chromium)"
}

# WITH_DOCKER. Needs sys_docker_repo first. docker-ce is the daemon,
# docker-ce-cli the client, containerd.io the runtime under both. Neither
# plugin comes with the others: without docker-compose-plugin there is no
# `docker compose` at all.
sys_docker_engine() {
  apt_ensure docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  # The `docker` group exists only after docker-ce lands. Without it every
  # docker call on the box needs sudo.
  if id dev >/dev/null 2>&1 && ! id -nG dev | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker dev
    sys_ok "dev added to the docker group"
  fi
  # Assert what the boot steps reach for, so a broken install fails here
  # rather than at the first boot. All three run without a daemon.
  [ -x /usr/bin/dockerd ] || sys_die "docker-ce installed, but /usr/bin/dockerd is missing."
  docker compose version >/dev/null || sys_die "docker compose does not run."
  docker buildx version >/dev/null || sys_die "docker buildx does not run."
  sys_ok "Docker Engine, Compose and Buildx present"
}

# --- the dev user --------------------------------------------------------------

# sys_dev_user [UID]. The image passes 1000, after it drops the base image's
# ubuntu user, so the home volume's owner is fixed. A VM passes nothing: the
# cloud image's own user usually holds 1000 and stays as the provider
# console's way in, so useradd takes the next free UID.
#
# The login shell comes from /etc/passwd, so zsh is the shell Tailscale SSH
# spawns from the first login, with no chsh. useradd only stores the path, so
# this can run before zsh is installed (the image does, to keep the user out
# of the package layer's cache).
sys_dev_user() {
  local uid="${1:-}" tmp
  if id dev >/dev/null 2>&1; then
    sys_ok "dev exists (uid $(id -u dev))"
  else
    local args=(--create-home --home-dir /home/dev --shell /usr/bin/zsh)
    if [ -n "${uid}" ]; then
      getent group dev >/dev/null 2>&1 || groupadd --gid "${uid}" dev
      args+=(--uid "${uid}" --gid dev)
    elif getent group dev >/dev/null 2>&1; then
      args+=(--gid dev)
    else
      args+=(--user-group)
    fi
    useradd "${args[@]}" dev
    sys_ok "created dev (uid $(id -u dev))"
  fi

  # /etc/sudoers.d arrives with the sudo package, which may not be installed
  # yet. dpkg leaves an existing directory and the drop-in inside it alone
  # when sudo lands later. visudo checks the file when it is there to ask.
  mkdir -p /etc/sudoers.d
  tmp="$(mktemp)"
  echo 'dev ALL=(ALL) NOPASSWD:ALL' > "${tmp}"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cqf "${tmp}" || sys_die "visudo rejected the dev sudoers drop-in."
  fi
  put_file "${tmp}" /etc/sudoers.d/dev 440
  rm -f "${tmp}"
  sys_ok "passwordless sudo"

  if getent group docker >/dev/null 2>&1 && ! id -nG dev | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker dev
    sys_ok "dev added to the docker group"
  fi
}

# --- the devaloy CLI -----------------------------------------------------------

# sys_install_cli REPO_DIR. The three scripts in /usr/local/bin, lib/ in
# /usr/local/lib/devaloy, and the old verb names as symlinks. A file in the
# lib directory that the repo no longer has is removed, which a fresh image
# gets for free. `devaloy` refuses to start when one of its modules is
# missing, so this copies all of lib/, never a list.
sys_install_cli() {
  local src="$1" f rel mode
  for f in devaloy bootstrap-toolchain.sh link-shims; do
    put_file "${src}/${f}" "${SYS_BIN_DIR}/${f}" 755
  done
  mkdir -p "${SYS_LIB_DIR}"
  while IFS= read -r f; do
    rel="${f#"${src}/lib/"}"
    mode=644
    [ -x "${f}" ] && mode=755
    put_file "${f}" "${SYS_LIB_DIR}/${rel}" "${mode}"
  done < <(find "${src}/lib" -type f | sort)
  while IFS= read -r f; do
    rel="${f#"${SYS_LIB_DIR}/"}"
    [ -e "${src}/lib/${rel}" ] || rm -f "${f}"
  done < <(find "${SYS_LIB_DIR}" -type f)
  for f in "${SYS_OLD_VERBS[@]}"; do
    [ "$(readlink "${SYS_BIN_DIR}/${f}" 2>/dev/null)" = "${SYS_BIN_DIR}/devaloy" ] ||
      ln -sfn "${SYS_BIN_DIR}/devaloy" "${SYS_BIN_DIR}/${f}"
  done
  sys_ok "devaloy, bootstrap-toolchain.sh, link-shims, ${SYS_LIB_DIR}"
}

# --- build-flags ---------------------------------------------------------------

# sys_build_flags DIR RUNTIME WITH_DOCKER WITH_BROWSER. What the box was built
# with, for `devaloy doctor`. "Docker is not reachable" is the same
# observation whether the box never had Docker or the daemon died, and those
# need opposite answers; this file says which was asked for. RUNTIME
# (container, native or upstash) decides what doctor and health check. WITH_PASEO
# and WITH_T3CODE are runtime flags and live in runtime-flags instead. Any other
# RUNTIME is refused here: the readers turn an unknown value into container,
# so a typo written now would pass as the wrong runtime with no error.
sys_build_flags() {
  case "$2" in
    container|native|upstash) ;;
    *) sys_die "build-flags: RUNTIME=$2 is not container, native or upstash." ;;
  esac
  put_content "$1/build-flags" 644 < <(
    printf 'WITH_DOCKER=%s\nWITH_BROWSER=%s\nRUNTIME=%s\n' "$3" "$4" "$2")
  sys_ok "build-flags: WITH_DOCKER=$3 WITH_BROWSER=$4 RUNTIME=$2"
}
