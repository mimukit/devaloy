#!/usr/bin/env bash
# Run system install steps by name. The Dockerfile calls this, one RUN per
# step; scripts/install-native.sh sources lib/system/steps.sh and calls the
# functions itself.
#
#   lib/system/install.sh STEP...
#
# Steps, in the order a fresh box needs them:
#
#   tailscale-repo     Tailscale's apt keyring and list for this distro
#   docker-repo        Docker's apt keyring and list for this distro
#   zsh-completions    the pinned zsh-completions tarball
#   dev-user           the dev user (DEV_UID, or the next free UID) and sudo
#   base-packages      config/apt/packages.txt, plus the bat and fd names
#   browser-packages   config/apt/browser.txt, when WITH_BROWSER=true
#   docker-engine      Docker Engine and its plugins, when WITH_DOCKER=true
#   cli                devaloy, its two scripts, lib/ and the old verb names
#   build-flags        FLAGS_DIR/build-flags from RUNTIME, WITH_DOCKER and
#                      WITH_BROWSER
#
# Environment:
#
#   REPO            the devaloy checkout to read config/ and lib/ from;
#                   default: the checkout this script is in
#   SYS_ROOT        write repo files under this root (the image's fetch stage)
#   DEV_UID         a fixed UID for dev-user
#   WITH_DOCKER     true or false, default false
#   WITH_BROWSER    true or false, default false
#   RUNTIME         container or native, for build-flags
#   FLAGS_DIR       where build-flags goes, default /opt/devaloy
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "${here}/../.." && pwd)}"
WITH_DOCKER="${WITH_DOCKER:-false}"
WITH_BROWSER="${WITH_BROWSER:-false}"
FLAGS_DIR="${FLAGS_DIR:-/opt/devaloy}"

# shellcheck source=lib/system/common.sh
. "${here}/common.sh"
# shellcheck source=lib/system/steps.sh
. "${here}/steps.sh"

[ $# -gt 0 ] || { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

for step in "$@"; do
  case "${step}" in
    tailscale-repo)   sys_tailscale_repo ;;
    docker-repo)      sys_docker_repo ;;
    zsh-completions)  sys_zsh_completions ;;
    dev-user)         sys_dev_user "${DEV_UID:-}" ;;
    base-packages)    sys_base_packages "${REPO}" ;;
    browser-packages)
      if [ "${WITH_BROWSER}" = true ]; then sys_browser_packages "${REPO}"
      else sys_ok "browser libraries skipped (WITH_BROWSER=${WITH_BROWSER})"; fi
      ;;
    docker-engine)
      if [ "${WITH_DOCKER}" = true ]; then sys_docker_engine
      else sys_ok "Docker Engine skipped (WITH_DOCKER=${WITH_DOCKER})"; fi
      ;;
    cli)              sys_install_cli "${REPO}" ;;
    build-flags)
      [ -n "${RUNTIME:-}" ] || sys_die "build-flags needs RUNTIME=container or RUNTIME=native."
      sys_build_flags "${FLAGS_DIR}" "${RUNTIME}" "${WITH_DOCKER}" "${WITH_BROWSER}"
      ;;
    *) sys_die "install.sh: unknown step '${step}'. Run it with no arguments for the list." ;;
  esac
done
