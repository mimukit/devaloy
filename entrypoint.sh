#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
MISE_NODE_VERSION="lts"
MISE_HERDR_VERSION="${MISE_HERDR_VERSION:-latest}"

log() { echo "[entrypoint] $*"; }

mkdir -p /run/sshd

# --- authorized_keys (materialized from PUBLIC_KEY every boot) ---
mkdir -p "${DEV_HOME}/.ssh"
if [ -n "${PUBLIC_KEY:-}" ]; then
  printf '%s\n' "${PUBLIC_KEY}" > "${DEV_HOME}/.ssh/authorized_keys"
else
  log "WARNING: PUBLIC_KEY is empty — no key will be able to log in."
  : > "${DEV_HOME}/.ssh/authorized_keys"
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

# --- skeleton dotfiles (only if the home volume is empty) ---
if [ ! -f "${DEV_HOME}/.bashrc" ]; then
  log "Seeding skeleton dotfiles into empty home volume"
  cp -a /etc/skel/. "${DEV_HOME}/"
  chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"
fi

# --- mise bootstrap + pinned toolchain (idempotent, runs as dev) ---
MISE_MARKER="${DEV_HOME}/.local/share/mise/.devaloy-bootstrapped"
if [ ! -f "${MISE_MARKER}" ]; then
  log "Bootstrapping mise + toolchain"
  su - "${DEV_USER}" -c '
    set -euo pipefail
    curl -fsSL https://mise.run | sh
    export PATH="$HOME/.local/bin:$PATH"
    mise use -g node@'"${MISE_NODE_VERSION}"'
    mise use -g pnpm@latest
    mise use -g gh@latest
    mise use -g npm:turbo@latest
    mise use -g herdr@'"${MISE_HERDR_VERSION}"'
    mise install
  '
  mkdir -p "$(dirname "${MISE_MARKER}")"
  touch "${MISE_MARKER}"
else
  log "mise toolchain already bootstrapped, skipping"
fi

# --- shell profile: mise activation + login hint ---
PROFILE_SNIPPET="${DEV_HOME}/.devaloy_profile"
if [ ! -f "${PROFILE_SNIPPET}" ]; then
  cat > "${PROFILE_SNIPPET}" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"

# Reset oom_score_adj for interactive sessions so a heavy build (not sshd
# itself) is the kernel's preferred OOM-kill target. See entrypoint.sh.
echo 0 > /proc/self/oom_score_adj 2>/dev/null || true

if [ -n "${SSH_TTY:-}" ]; then
  echo "devaloy devbox — run: herdr"
fi
EOF
  chown "${DEV_USER}:${DEV_USER}" "${PROFILE_SNIPPET}"
fi
if ! grep -qF '.devaloy_profile' "${DEV_HOME}/.bashrc" 2>/dev/null; then
  echo '[ -f "$HOME/.devaloy_profile" ] && . "$HOME/.devaloy_profile"' >> "${DEV_HOME}/.bashrc"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.bashrc"
fi

# OOM safety: OpenSSH sets its own oom_score_adj to -1000 at startup when
# running as root with CAP_SYS_RESOURCE (see compose.yml), protecting the
# master process from the kernel OOM killer. The profile snippet above resets
# interactive login shells back to 0, so a runaway build is what gets killed.
log "Starting sshd on port 2222"
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
