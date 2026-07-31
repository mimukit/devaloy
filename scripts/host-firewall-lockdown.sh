#!/usr/bin/env bash
# Hardens the HOST's own sshd/mgmt surface on a cloud VPS. Defense-in-depth —
# not what protects the devbox itself (the tailscale sidecar already
# publishes nothing to the host). Skippable on a trusted/home Docker host.
set -euo pipefail

TS_IFACE="${TS_IFACE:-tailscale0}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo — ufw needs root." >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw not found — install it first (e.g. apt install ufw)." >&2
  exit 1
fi

# Anti-lockout guard 1: Tailscale must be up on this host.
if ! command -v tailscale >/dev/null 2>&1 || ! tailscale ip -4 >/dev/null 2>&1; then
  echo "Tailscale is not up on this host — refusing to lock down (anti-lockout guard)." >&2
  exit 1
fi

if ! ip link show "${TS_IFACE}" >/dev/null 2>&1; then
  echo "Interface ${TS_IFACE} not found — set TS_IFACE to the right name and re-run." >&2
  exit 1
fi

# Anti-lockout guard 2: Tailscale being up is not enough — if you are logged in
# over the public IP, enabling this drops your own session. Tailnet addresses
# live in 100.64.0.0/10, so check where this SSH session actually came from.
SSH_SRC="${SSH_CONNECTION%% *}"
if [ -n "${SSH_SRC}" ] && ! printf '%s' "${SSH_SRC}" | grep -qE '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'; then
  echo "This SSH session is from ${SSH_SRC}, which is not a tailnet address." >&2
  echo "Enabling the firewall now would cut you off. Reconnect over Tailscale first," >&2
  echo "or re-run with ALLOW_NON_TAILNET=1 if you are certain." >&2
  [ "${ALLOW_NON_TAILNET:-}" = "1" ] || exit 1
fi

echo "Tailscale is up ($(tailscale ip -4)). Locking down the host firewall..."

ufw default deny incoming
ufw default allow outgoing
ufw allow in on "${TS_IFACE}"
ufw --force enable

echo "Done: incoming denied by default except on ${TS_IFACE}. No 80/443 opened."
echo "Verify with: ufw status verbose"
