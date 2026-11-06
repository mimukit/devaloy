#!/usr/bin/env bash
# devaloy on a native VM: the per-boot work, run by devaloy-boot.service.
#
# The native twin of entrypoint.sh. It sources the same step files and calls
# the same steps in the same order, so a native VM and the container cannot
# drift apart in what a boot writes. What it leaves out is everything that
# starts a process, because systemd owns those here:
#
#   tailscaled        the tailscale package's own unit
#   dockerd           docker.service, from Docker's apt repo (WITH_DOCKER)
#   the Paseo daemon  devaloy-paseo.service, through native-serve.sh
#   the T3 server     devaloy-t3code.service, through native-serve.sh
#
# The inputs come from /etc/devaloy/env, which the unit loads with
# EnvironmentFile=. The steps read the environment exactly as they do in the
# container, so nothing here re-reads that file.
#
# Two modes:
#
#   native-boot.sh                 the boot (devaloy-boot.service ExecStart)
#   native-boot.sh paseo-plugins   install PASEO_PLUGINS in the background
#                                  (devaloy-paseo.service ExecStartPost)
#
# Installed with lib/ to /usr/local/lib/devaloy/steps by
# scripts/install-native.sh. Runs as root.
set -euo pipefail

# The runtime is not a guess here: this script only ever runs on a native VM.
# Set before common.sh resolves it, so the log prefix and every recovery hint
# take the native branch even if build-flags is missing.
export RUNTIME=native

DEVALOY_LIB="${DEVALOY_LIB:-/usr/local/lib/devaloy}"
# shellcheck source=lib/steps/common.sh
. "${DEVALOY_LIB}/steps/common.sh"
# shellcheck source=lib/steps/env.sh
. "${DEVALOY_LIB}/steps/env.sh"
# shellcheck source=lib/steps/tailscale.sh
. "${DEVALOY_LIB}/steps/tailscale.sh"
# shellcheck source=lib/steps/toolchain.sh
. "${DEVALOY_LIB}/steps/toolchain.sh"
# shellcheck source=lib/steps/git.sh
. "${DEVALOY_LIB}/steps/git.sh"
# shellcheck source=lib/steps/paseo.sh
. "${DEVALOY_LIB}/steps/paseo.sh"
# shellcheck source=lib/steps/t3code.sh
. "${DEVALOY_LIB}/steps/t3code.sh"

# The ports the two services bind. native-serve.sh carries the same numbers;
# both match entrypoint.sh.
PASEO_PORT=6767
T3CODE_PORT=3773

native_boot() {
  # --- the dev shell, secrets and dotfiles ---
  step_shell_env
  step_browser_env
  step_shell_hooks
  step_retire_banner
  step_secrets
  step_push_config
  step_seed_config
  step_claude_onboarding

  # --- Tailscale SSH ---
  # tailscaled is already running: the unit orders this one after it. A node
  # that rejoined from its saved state is left alone; see
  # step_tailscale_ensure.
  step_tailscale_ensure

  # --- Docker ---
  # Nothing to do at boot. The container copies config/docker/daemon.json on
  # every boot with step_docker_config, but here the installer owns
  # /etc/docker/daemon.json, because it may move the address ranges off the
  # repo defaults when they collide with this VM's network. Copying the repo
  # file here would undo that on every boot.

  # --- mise bootstrap + pinned toolchain (runs as dev) ---
  step_browser_libs_check
  step_runtime_flags
  step_toolchain
  step_t3code_upgrade
  step_link_shims

  # --- git: gh auth, identity, signing, clones ---
  # Same order as entrypoint.sh, for the reasons given there.
  step_gh_auth
  step_git_identity
  step_signing
  step_clone_repos

  # --- Paseo (WITH_PASEO=true) ---
  # The config file only. devaloy-paseo.service starts the daemon after this
  # unit finishes, and its ExecStartPost installs the plugins.
  if [ "${WITH_PASEO:-false}" = "true" ]; then
    if as_dev "command -v paseo >/dev/null 2>&1"; then
      PASEO_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
      if [ -n "${PASEO_IP}" ]; then
        step_paseo_config
        log "Paseo daemon on ${PASEO_IP}:${PASEO_PORT} — add it in the app under"
        log "Settings > Add host > Direct connection, with SSL off. The relay is"
        log "deliberately disabled, so the phone needs Tailscale connected."
      else
        log "WARNING: no tailnet IPv4 — the Paseo daemon cannot bind its address."
        log "WARNING: fix the tailscale failure above, then run"
        log "WARNING: 'sudo systemctl restart devaloy-boot devaloy-paseo'."
      fi
    else
      log "WARNING: WITH_PASEO is true but paseo is not installed. The toolchain"
      log "WARNING: bootstrap above did not finish — once you are in, re-run it"
      log "WARNING: with: devaloy-update"
    fi
  fi

  # --- T3 Code (WITH_T3CODE=true) ---
  if [ "${WITH_T3CODE:-false}" = "true" ]; then
    if as_dev "command -v t3 >/dev/null 2>&1"; then
      T3CODE_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
      if [ -n "${T3CODE_IP}" ]; then
        step_t3code_config
        log "T3 Code server on http://${T3CODE_IP}:${T3CODE_PORT} — pair the first device"
        log "with the link in 'journalctl -u devaloy-t3code'. For the next one, run on"
        log "your laptop:"
        log "  ssh dev@${TS_HOSTNAME:-devaloy} t3 pair"
        log "Keep Tailscale connected on the phone."
      else
        log "WARNING: no tailnet IPv4 — the T3 Code server cannot bind its address."
        log "WARNING: fix the tailscale failure above, then run"
        log "WARNING: 'sudo systemctl restart devaloy-boot devaloy-t3code'."
      fi
    else
      log "WARNING: WITH_T3CODE is true but t3 is not installed. The toolchain"
      log "WARNING: bootstrap above did not finish — once you are in, re-run it"
      log "WARNING: with: devaloy-update"
    fi
  fi

  # The container prints this line whatever the bootstrap did, because the
  # entrypoint must go on to supervise its processes. Here the unit's result
  # is the signal: the installer waits on it and promises to exit 0 only once
  # the toolchain is ready, and `devaloy doctor` reports a failed devaloy-boot.
  # So a failed bootstrap fails the unit, after every other step has run.
  if [ "${TOOLCHAIN_OK:-0}" != 1 ]; then
    log "WARNING: devaloy-boot failed because the toolchain bootstrap failed."
    log "WARNING: the box is reachable over Tailscale SSH. Once you are in, run"
    log "WARNING: 'devaloy update', then 'sudo systemctl restart devaloy-boot'."
    return 1
  fi
  log "devaloy is up. Connect with: ssh dev@${TS_HOSTNAME:-devaloy}"
}

# The Paseo plugins, from devaloy-paseo.service's ExecStartPost. The step waits
# up to two minutes for the daemon to answer, so it runs in the background, as
# the entrypoint runs it. The child stays in the unit's cgroup: it dies with
# the daemon and is started again with it, and a plugin that is already
# installed is skipped.
native_paseo_plugins() {
  [ -n "${PASEO_PLUGINS:-}" ] || return 0
  step_paseo_plugins &
}

case "${1:-boot}" in
  boot) native_boot ;;
  paseo-plugins) native_paseo_plugins ;;
  *)
    echo "native-boot.sh: unknown mode '$1' (expected boot or paseo-plugins)" >&2
    exit 2
    ;;
esac
