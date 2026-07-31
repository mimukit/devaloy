#!/usr/bin/env bash
# Hardens the HOST's own sshd/mgmt surface on a cloud VPS. Defense-in-depth —
# not what protects the devbox itself (the tailscale sidecar already
# publishes nothing to the host). Skippable on a trusted/home Docker host.
set -euo pipefail

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw not found — install it first (e.g. apt install ufw)." >&2
  exit 1
fi

# Anti-lockout guard: refuse to enable the firewall unless Tailscale is
# already up on this host, otherwise a mistake here can lock you out.
if ! command -v tailscale >/dev/null 2>&1 || ! tailscale ip -4 >/dev/null 2>&1; then
  echo "Tailscale is not up on this host — refusing to lock down (anti-lockout guard)." >&2
  exit 1
fi

echo "Tailscale is up ($(tailscale ip -4)). Locking down the host firewall..."

ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw --force enable

echo "Done: incoming denied by default except on tailscale0. No 80/443 opened."
echo "Verify with: ufw status verbose"
