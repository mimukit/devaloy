#!/usr/bin/env bash
# devaloy on a native VM: start the Paseo daemon or the T3 Code server.
#
#   native-serve.sh paseo     ExecStart of devaloy-paseo.service
#   native-serve.sh t3code    ExecStart of devaloy-t3code.service
#
# The native twin of the two restart loops at the bottom of entrypoint.sh.
# systemd is the loop here (Restart=always, RestartSec=10, the same 10 s the
# container sleeps), so this script does one pass: find the tailnet address,
# then exec the server in its place, so systemd supervises the server itself.
#
# It runs as dev (User=dev in the unit), where the container runs the same
# command through as_dev, which is `su -l -s /bin/sh dev`. That `su -l` is
# what decides the server's environment in the container: a login reset to
# HOME, USER, LOGNAME, SHELL and the default PATH, plus whatever
# ~/.devaloy_secrets exports. The unit, though, loads all of /etc/devaloy/env,
# which also holds TS_AUTHKEY, the signing key and the ntfy token, and every
# agent the server spawns would inherit them. So the exec goes through
# `env -i` and rebuilds the `su -l` environment by hand. The server ends up
# with the same variables it has in the container, and no more.
#
# A failure exits non-zero with the same warning the container prints, and
# systemd retries in 10 s. That is the container's loop, with the log in
# `journalctl -u devaloy-paseo` or `journalctl -u devaloy-t3code`.
set -euo pipefail

TS_SOCKET="/var/run/tailscale/tailscaled.sock"
SECRETS_SNIPPET="${HOME:-/home/dev}/.devaloy_secrets"
PASEO_PORT=6767
T3CODE_PORT=3773

log() { echo "[devaloy] $*"; }

# The `su -l` environment, as `su -l -s /bin/sh` prints it on ubuntu:24.04.
# PATH is the one from /etc/environment: the mise shims are not on it, and the server
# finds `claude`, `codex`, `paseo` and `t3` through the /usr/local/bin mirror
# that link-shims keeps, exactly as in the container. SHELL is zsh for the
# reason spelt out at the Paseo loop in entrypoint.sh: the servers open their
# terminals from $SHELL.
login_env=(
  env -i
  HOME="${HOME:-/home/dev}"
  USER="${USER:-dev}"
  LOGNAME="${LOGNAME:-dev}"
  MAIL="/var/mail/${USER:-dev}"
  SHELL=/usr/bin/zsh
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
)
[ -n "${LANG:-}" ] && login_env+=(LANG="${LANG}")

tailnet_ip() {
  tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true
}

# The secrets file is sourced for the reason given at the Paseo loop in
# entrypoint.sh: agents inherit the server's environment, so without it
# CLAUDE_CODE_OAUTH_TOKEN never reaches a session started from the phone. The
# `if [ -f ]` guard is load-bearing for the dash reason given there too.
secrets_line="if [ -f '${SECRETS_SNIPPET}' ]; then . '${SECRETS_SNIPPET}'; fi;"

serve_paseo() {
  if ! command -v /usr/local/bin/paseo >/dev/null 2>&1; then
    log "WARNING: WITH_PASEO is true but paseo is not installed. The toolchain"
    log "WARNING: bootstrap did not finish — once you are in, re-run it"
    log "WARNING: with: devaloy-update"
    exit 1
  fi
  ip="$(tailnet_ip)"
  if [ -z "${ip}" ]; then
    log "WARNING: no tailnet IPv4 — not starting the Paseo daemon."
    log "WARNING: fix tailscale ('sudo tailscale up --ssh'); this unit retries in 10s."
    exit 1
  fi

  # The fallback the container takes when step_paseo_config could not write
  # ~/.paseo/config.json (PASEO_START_ENV in entrypoint.sh). devaloy-boot
  # writes that file, so here the test is whether it holds this address: when
  # it does not, the daemon gets the address from the environment instead,
  # and binds the tailnet IP either way.
  start_env=""
  if ! jq -e --arg l "${ip}:${PASEO_PORT}" '.daemon.listen == $l' \
       "${HOME:-/home/dev}/.paseo/config.json" >/dev/null 2>&1; then
    log "WARNING: ~/.paseo/config.json does not listen on ${ip}:${PASEO_PORT}."
    log "WARNING: starting the daemon from the environment instead. Run"
    log "WARNING: 'sudo systemctl restart devaloy-boot' to rewrite the file."
    start_env="export PASEO_RELAY_ENABLED=false PASEO_LISTEN='${ip}:${PASEO_PORT}';"
    if [ "${WITH_PASEO_WEB_UI:-false}" = "true" ]; then
      start_env="${start_env} export PASEO_WEB_UI_ENABLED=true PASEO_HOSTNAMES='${TS_HOSTNAME:-devaloy},.ts.net';"
    fi
  fi

  log "starting the Paseo daemon on ${ip}:${PASEO_PORT}"
  exec "${login_env[@]}" /bin/sh -c "${start_env} ${secrets_line} exec paseo daemon run"
}

serve_t3code() {
  if ! command -v /usr/local/bin/t3 >/dev/null 2>&1; then
    log "WARNING: WITH_T3CODE is true but t3 is not installed. The toolchain"
    log "WARNING: bootstrap did not finish — once you are in, re-run it"
    log "WARNING: with: devaloy-update"
    exit 1
  fi
  ip="$(tailnet_ip)"
  if [ -z "${ip}" ]; then
    log "WARNING: no tailnet IPv4 — not starting the T3 Code server."
    log "WARNING: fix tailscale ('sudo tailscale up --ssh'); this unit retries in 10s."
    exit 1
  fi

  # The two variables are the ones the container loop sets, for the reasons
  # given there. T3CODE_SERVER_BROWSER_SANDBOX=0 is kept on the VM too: Ubuntu
  # 24.04 restricts unprivileged user namespaces through AppArmor, which is
  # what Chrome's own sandbox needs, so the container's answer still holds.
  log "starting the T3 Code server on http://${ip}:${T3CODE_PORT}"
  exec "${login_env[@]}" /bin/sh -c "export T3CODE_TELEMETRY_ENABLED=false T3CODE_SERVER_BROWSER_SANDBOX=0; \
    ${secrets_line} exec t3 serve --host '${ip}' --port '${T3CODE_PORT}' --no-browser"
}

case "${1:-}" in
  paseo) serve_paseo ;;
  t3code) serve_t3code ;;
  *)
    echo "native-serve.sh: expected paseo or t3code, got '${1:-}'" >&2
    exit 2
    ;;
esac
