#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
# Version pins live in bootstrap-toolchain.sh; these are only forwarded, so an
# empty value here falls through to that script's default.

log() { echo "[entrypoint] $*"; }

mkdir -p /run/sshd

# --- authorized_keys (materialized from PUBLIC_KEY every boot) ---
mkdir -p "${DEV_HOME}/.ssh"
if [ -n "${PUBLIC_KEY:-}" ]; then
  # %b (not %s) so a literal "\n" between keys works too — whether compose's
  # dotenv parser expands the escape or passes it through, multiple keys land
  # on separate lines either way.
  printf '%b\n' "${PUBLIC_KEY}" > "${DEV_HOME}/.ssh/authorized_keys"
elif [ -s "${DEV_HOME}/.ssh/authorized_keys" ]; then
  # Never destroy the only credential. A redeploy with the env file missing
  # would otherwise lock you out of a running devbox permanently.
  log "WARNING: PUBLIC_KEY is empty — keeping the existing authorized_keys."
else
  log "WARNING: PUBLIC_KEY is empty and no authorized_keys exists — nobody can log in."
  touch "${DEV_HOME}/.ssh/authorized_keys"
fi
chmod 700 "${DEV_HOME}/.ssh"
chmod 600 "${DEV_HOME}/.ssh/authorized_keys"
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"

# --- host keys (generated once into the persistent volume, absent-only) ---
HOST_KEY_DIR="${DEV_HOME}/.ssh/host_keys"
mkdir -p "${HOST_KEY_DIR}"
for kind in rsa ecdsa ed25519; do
  key_file="${HOST_KEY_DIR}/ssh_host_${kind}_key"
  if [ ! -f "${key_file}" ]; then
    log "Generating missing ${kind} host key"
    ssh-keygen -q -t "${kind}" -f "${key_file}" -N ""
  fi
done
chown -R root:root "${HOST_KEY_DIR}"
chmod 700 "${HOST_KEY_DIR}"
chmod 600 "${HOST_KEY_DIR}"/ssh_host_*_key
chmod 644 "${HOST_KEY_DIR}"/ssh_host_*_key.pub

# --- mise bootstrap + pinned toolchain (once per volume, runs as dev) ---
# Deliberately NOT fatal: if this fails, sshd must still start, or a network
# blip on first boot leaves an unreachable box in a restart loop with no way
# in to diagnose it. The marker is only written on success, so a later boot
# (or `devaloy-update`) retries cleanly.
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
    log "WARNING: toolchain bootstrap failed — starting sshd anyway so the box stays reachable."
    log "WARNING: once you are in, re-run it with: devaloy-update"
  fi
else
  log "mise toolchain already bootstrapped, skipping (run devaloy-update to refresh)"
fi

# --- shell env: toolchain PATH + OOM reset, for EVERY shell ---
# Ubuntu's stock .bashrc bails out early on non-interactive shells, so anything
# appended to the end is invisible to `ssh devbox 'pnpm build'`, rsync, scp and
# git-over-ssh. This snippet is sourced from the TOP of .bashrc instead, above
# that guard. mise shims resolve versions at exec time, so they need no
# interactive `mise activate`.
ENV_SNIPPET="${DEV_HOME}/.devaloy_env"
cat > "${ENV_SNIPPET}" <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# The container starts at a negative oom_score_adj (see compose.yml) to keep
# sshd off the OOM killer's list. Raise every session back to 0 so a runaway
# build inherits 0 and is killed before the process that keeps you connected.
# Raising is unprivileged; only lowering needs CAP_SYS_RESOURCE.
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
if [ -n "${SSH_TTY:-}" ]; then
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

# OOM safety: compose sets this container's oom_score_adj negative, which sshd
# inherits, so the kernel avoids killing the process that keeps the box
# reachable. The env snippet above raises each session back to 0 so a runaway
# build is the preferred victim instead.
log "Starting sshd on port 2222"
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
