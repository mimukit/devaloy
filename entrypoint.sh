#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"
CONFIG_SRC="/opt/devaloy/config"
# Version pins live in bootstrap-toolchain.sh; these are only forwarded, so an
# empty value here falls through to that script's default.

log() { echo "[entrypoint] $*"; }

# Run a command as the dev user under a plain sh. The explicit -s matters now
# that the dev user's login shell is zsh: without it every helper below would
# run through a shell whose startup files this script is in the middle of
# rewriting. -l gives a clean environment and a correct HOME.
as_dev() { su -l -s /bin/sh "${DEV_USER}" -c "$1"; }

# --- shell env: toolchain PATH + OOM reset, for EVERY shell ---
# Written before tailscaled comes up, so the very first session that lands
# already has it. Ubuntu's stock .bashrc bails out early on non-interactive
# shells, so this is sourced from the TOP of .bashrc, above that guard; for zsh
# it hangs off .zshenv, which zsh sources for *every* invocation including
# `ssh devbox '<cmd>'`. mise shims resolve versions at exec time, so no
# interactive `mise activate` is needed. link-shims covers whatever is left.
ENV_SNIPPET="${DEV_HOME}/.devaloy_env"
cat > "${ENV_SNIPPET}" <<'EOF'
# Idempotent: this file is reachable from .zshenv, .zshrc and .bashrc, and a
# blind prepend would stack duplicate entries onto PATH on every nested shell.
# Listed back-to-front because each iteration prepends: the last one processed
# ends up first, and ~/.local/bin has to win — it is where a hand-run vendor
# installer puts things, and that copy should shadow the packaged one.
for _devaloy_dir in "$HOME/.local/share/mise/shims" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_devaloy_dir:"*) ;;
    *) PATH="$_devaloy_dir:$PATH" ;;
  esac
done
unset _devaloy_dir
export PATH

# Tokens live in a separate 0600 file so this one stays safe to cat.
[ -f "$HOME/.devaloy_secrets" ] && . "$HOME/.devaloy_secrets"

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

if ! grep -qF '.devaloy_env' "${DEV_HOME}/.zshenv" 2>/dev/null; then
  # shellcheck disable=SC2016  # as above, $HOME stays literal.
  echo '[ -f "$HOME/.devaloy_env" ] && . "$HOME/.devaloy_env"' >> "${DEV_HOME}/.zshenv"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.zshenv"
fi

# --- retire the old login banner ---
# It printed on every interactive session and earned nothing. Removed from the
# image, and swept out of home volumes created before that change.
rm -f "${DEV_HOME}/.devaloy_profile"
if [ -f "${DEV_HOME}/.bashrc" ] && grep -qF '.devaloy_profile' "${DEV_HOME}/.bashrc"; then
  sed -i '/\.devaloy_profile/d' "${DEV_HOME}/.bashrc"
fi

# --- GITHUB_TOKEN ---
# Written to a file rather than relied on from the container environment:
# tailscaled spawns login shells itself, and what it forwards from PID 1's
# environment is its business, not a contract. Rewritten from scratch on every
# boot, so clearing the variable in .env and redeploying really does revoke it.
SECRETS_SNIPPET="${DEV_HOME}/.devaloy_secrets"
rm -f "${SECRETS_SNIPPET}"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SECRETS_SNIPPET}"
  # Single-quote the value and escape any embedded quote, so a token with shell
  # metacharacters cannot execute anything when this file is sourced.
  printf "export GITHUB_TOKEN='%s'\n" \
    "$(printf '%s' "${GITHUB_TOKEN}" | sed "s/'/'\\\\''/g")" >> "${SECRETS_SNIPPET}"
  log "GITHUB_TOKEN wired into the dev shell environment"
fi

# --- managed dotfiles (zsh, Claude Code, Codex) ---
# The repo is the source of truth: every file shipped under config/ is copied
# over its counterpart in /home/dev on each boot, so editing one in the repo
# and redeploying actually changes the box. The copy MERGES rather than
# replaces, so files the repo does not ship — ~/.zshrc.local, credentials,
# session history, skills you added by hand — are left alone.
seed_config() {
  src="$1"; dest="$2"
  [ -d "${src}" ] || return 0
  as_dev "mkdir -p '${dest}' && cp -R '${src}/.' '${dest}/'"
}
if [ -d "${CONFIG_SRC}" ]; then
  as_dev "cp -f '${CONFIG_SRC}/zsh/zshrc' '${DEV_HOME}/.zshrc'"
  seed_config "${CONFIG_SRC}/claude" "${DEV_HOME}/.claude"
  seed_config "${CONFIG_SRC}/codex"  "${DEV_HOME}/.codex"
  log "Managed dotfiles synced from ${CONFIG_SRC}"
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

# --- mise bootstrap + pinned toolchain (runs as dev) ---
# The skip-if-already-installed decision lives in bootstrap-toolchain.sh, not
# here: it is gated on that script's TOOLSET_REVISION, and only the script knows
# what revision it ships. Keeping the check next to the tool list is what stops
# a newly added tool from being skipped forever on a volume that was
# provisioned before it existed.
#
# Deliberately NOT fatal: a network blip on first boot must not take the box
# down. The revision marker is only written on success, so a later boot (or
# `devaloy-update`) retries cleanly.
log "Checking the mise toolchain"
if as_dev "MISE_NODE_VERSION='${MISE_NODE_VERSION:-}' \
    MISE_HERDR_VERSION='${MISE_HERDR_VERSION:-}' \
    /usr/local/bin/bootstrap-toolchain.sh"; then
  log "Toolchain ready"
else
  log "WARNING: toolchain bootstrap failed — the box is still reachable."
  log "WARNING: once you are in, re-run it with: devaloy-update"
fi

# Make the toolchain resolvable from sessions that never source .bashrc.
DEV_HOME="${DEV_HOME}" /usr/local/bin/link-shims || \
  log "WARNING: link-shims failed — non-interactive commands may not find the toolchain."

# --- git over HTTPS via GITHUB_TOKEN ---
# gh picks the token up from the environment on its own; this only teaches git
# to ask gh for credentials, so `git push` works without a second login. Run
# after link-shims because that is what puts gh on root's PATH. The token is
# read from the 0600 file rather than passed on the command line, where it
# would be readable in /proc for the life of the call.
if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
  # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
  if as_dev '. "$HOME/.devaloy_secrets" && gh auth setup-git' 2>/dev/null; then
    log "git configured to authenticate to GitHub through gh"
  else
    log "WARNING: gh auth setup-git failed — 'git push' over HTTPS may prompt."
  fi
fi

log "devaloy is up. Connect with: ssh dev@${TS_HOSTNAME:-devbox}"
wait "${TAILSCALED_PID}"
