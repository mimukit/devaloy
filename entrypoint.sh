#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"
# Version pins live in bootstrap-toolchain.sh; these are only forwarded, so an
# empty value here falls through to that script's default.

log() { echo "[entrypoint] $*"; }

# --- shell env: toolchain PATH + OOM reset, for EVERY shell ---
# Written before tailscaled comes up, so the very first session that lands
# already has it. Ubuntu's stock .bashrc bails out early on non-interactive
# shells, so this is sourced from the TOP of .bashrc, above that guard. mise
# shims resolve versions at exec time, so no interactive `mise activate` is
# needed. link-shims covers the shells that skip .bashrc entirely.
ENV_SNIPPET="${DEV_HOME}/.devaloy_env"
cat > "${ENV_SNIPPET}" <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# The container starts at a negative oom_score_adj (see compose.yml) to keep
# tailscaled off the OOM killer's list. Raise every session back to 0 so a
# runaway build inherits 0 and is killed before the process that keeps you
# connected. Raising is unprivileged; only lowering needs CAP_SYS_RESOURCE.
echo 0 > /proc/self/oom_score_adj 2>/dev/null || true
EOF
chown "${DEV_USER}:${DEV_USER}" "${ENV_SNIPPET}"

if ! grep -qF '.devaloy_env' "${DEV_HOME}/.bashrc" 2>/dev/null; then
  touch "${DEV_HOME}/.bashrc"
  {
    # shellcheck disable=SC2016  # $HOME must stay literal — the dev user's
    # shell expands it at login, not this script.
    printf '%s\n' '[ -f "$HOME/.devaloy_env" ] && . "$HOME/.devaloy_env"'
    cat "${DEV_HOME}/.bashrc"
  } > "${DEV_HOME}/.bashrc.new"
  mv "${DEV_HOME}/.bashrc.new" "${DEV_HOME}/.bashrc"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.bashrc"
fi

# --- login hint (interactive sessions only) ---
# Deliberately NOT auto-attaching herdr: that breaks scp/sftp/rsync and
# git-over-ssh. Appended after .bashrc's interactivity guard on purpose.
PROFILE_SNIPPET="${DEV_HOME}/.devaloy_profile"
if [ ! -f "${PROFILE_SNIPPET}" ]; then
  cat > "${PROFILE_SNIPPET}" <<'EOF'
if [ -t 0 ]; then
  echo "devaloy devbox — run: herdr"
fi
EOF
  chown "${DEV_USER}:${DEV_USER}" "${PROFILE_SNIPPET}"
fi
if ! grep -qF '.devaloy_profile' "${DEV_HOME}/.bashrc" 2>/dev/null; then
  # shellcheck disable=SC2016  # as above, $HOME stays literal.
  echo '[ -f "$HOME/.devaloy_profile" ] && . "$HOME/.devaloy_profile"' >> "${DEV_HOME}/.bashrc"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.bashrc"
fi

# --- tailscaled + Tailscale SSH (started FIRST, before the slow bootstrap) ---
# Ordering matters: the toolchain install takes minutes on a cold volume, and
# there is no sshd fallback any more. Bringing the tailnet up first means the
# box is reachable *during* that window rather than after it.
mkdir -p "${TS_STATE_DIR}" "$(dirname "${TS_SOCKET}")"

log "Starting tailscaled"
tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCKET}" \
  --tun=tailscale0 &
TAILSCALED_PID=$!

for _ in $(seq 1 30); do
  [ -S "${TS_SOCKET}" ] && break
  sleep 1
done
if [ ! -S "${TS_SOCKET}" ]; then
  log "WARNING: tailscaled socket never appeared — check NET_ADMIN and /dev/net/tun."
fi

# --accept-dns defaults to false: letting Tailscale rewrite /etc/resolv.conf in
# a container clobbers Docker's own resolver. Set TS_ACCEPT_DNS=true if you want
# MagicDNS resolution *from* the devbox.
# --timeout is load-bearing, not defensive: with no authkey and no saved state,
# `tailscale up` prints a login URL and blocks FOREVER. That would wedge the
# entrypoint before the toolchain bootstrap ever runs. Fail instead, and let the
# warning path below tell you how to finish the login by hand.
up_args=(--ssh --timeout=90s --hostname="${TS_HOSTNAME:-devbox}")
if [ "${TS_ACCEPT_DNS:-false}" = "true" ]; then
  up_args+=(--accept-dns=true)
else
  up_args+=(--accept-dns=false)
fi
# On a redeploy the node identity is already in the state volume, so the authkey
# is optional — only pass it when one is set.
if [ -n "${TS_AUTHKEY:-}" ]; then
  up_args+=(--authkey="${TS_AUTHKEY}")
fi

if tailscale --socket="${TS_SOCKET}" up "${up_args[@]}"; then
  log "Tailscale SSH is up as ${TS_HOSTNAME:-devbox} ($(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1))"
else
  # Deliberately non-fatal. Restart-looping would not fix a bad authkey or a
  # missing ACL rule, and it would destroy the one diagnostic path left.
  log "WARNING: tailscale up failed — this box is NOT reachable over the tailnet."
  if [ -z "${TS_AUTHKEY:-}" ]; then
    log "WARNING: TS_AUTHKEY is empty. Look further up this log for a"
    log "WARNING: 'To authenticate, visit: ...' URL and open it, or set the key."
  fi
  log "WARNING: recover from the Docker host with:"
  log "WARNING:   docker compose exec devbox tailscale up --ssh"
fi

# --- mise bootstrap + pinned toolchain (once per volume, runs as dev) ---
# Deliberately NOT fatal: a network blip on first boot must not take the box
# down. The marker is only written on success, so a later boot (or
# `devaloy-update`) retries cleanly.
MISE_MARKER="${DEV_HOME}/.local/share/mise/.devaloy-bootstrapped"
if [ ! -f "${MISE_MARKER}" ]; then
  log "Bootstrapping mise + toolchain"
  if su - "${DEV_USER}" -c "MISE_NODE_VERSION='${MISE_NODE_VERSION:-}' \
      MISE_HERDR_VERSION='${MISE_HERDR_VERSION:-}' \
      /usr/local/bin/bootstrap-toolchain.sh"; then
    mkdir -p "$(dirname "${MISE_MARKER}")"
    touch "${MISE_MARKER}"
    log "Toolchain bootstrap complete"
  else
    log "WARNING: toolchain bootstrap failed — the box is still reachable."
    log "WARNING: once you are in, re-run it with: devaloy-update"
  fi
else
  log "mise toolchain already bootstrapped, skipping (run devaloy-update to refresh)"
fi

# Make the toolchain resolvable from sessions that never source .bashrc.
DEV_HOME="${DEV_HOME}" /usr/local/bin/link-shims || \
  log "WARNING: link-shims failed — non-interactive commands may not find the toolchain."

log "devaloy is up. Connect with: ssh dev@${TS_HOSTNAME:-devbox}"
wait "${TAILSCALED_PID}"
