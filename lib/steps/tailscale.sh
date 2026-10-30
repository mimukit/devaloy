#!/usr/bin/env bash
# devaloy boot steps: join the tailnet with Tailscale SSH.
#
# Sourced by entrypoint.sh after common.sh, never executed. Starting tailscaled
# itself stays with the caller (the entrypoint in the container, the package's
# systemd unit on a native VM); this step only talks to the daemon through its
# socket, so it needs tailscaled to be up first. TS_SOCKET in common.sh is the
# path the tailscale package's own unit uses, so it holds on both.

# --accept-dns defaults to false in the container: letting Tailscale rewrite
# /etc/resolv.conf in a container clobbers Docker's own resolver. Set
# TS_ACCEPT_DNS=true if you want MagicDNS resolution *from* the box. On a native
# VM there is no Docker resolver to protect, so the default flips to true there;
# TS_ACCEPT_DNS=false still turns it off.
# --timeout is load-bearing, not defensive: with no authkey and no saved state,
# `tailscale up` prints a login URL and blocks FOREVER. That would wedge the
# entrypoint before the toolchain bootstrap ever runs. Fail instead, and let the
# warning path below tell you how to finish the login by hand.
step_tailscale_up() {
  up_args=(--ssh --timeout=90s --hostname="${TS_HOSTNAME:-devaloy}")
  accept_dns_default=false
  on_native && accept_dns_default=true
  if [ "${TS_ACCEPT_DNS:-${accept_dns_default}}" = "true" ]; then
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
    log "Tailscale SSH is up as ${TS_HOSTNAME:-devaloy} ($(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1))"
  else
    # Deliberately non-fatal. Restart-looping would not fix a bad authkey or a
    # missing ACL rule, and it would destroy the one diagnostic path left.
    log "WARNING: tailscale up failed — this box is NOT reachable over the tailnet."
    if [ -z "${TS_AUTHKEY:-}" ]; then
      log "WARNING: TS_AUTHKEY is empty. Look further up this log for a"
      log "WARNING: 'To authenticate, visit: ...' URL and open it, or set the key."
    fi
    # The way back in differs by runtime. A container has no shell of its own
    # without the tailnet, so the hint goes through the Docker host. A VM keeps
    # its public sshd and the provider console, and tailscaled is a systemd
    # unit there, so the same `up` runs from any root shell on the VM.
    if on_native; then
      log "WARNING: recover from a shell on this VM (public SSH or the provider"
      log "WARNING: console) with:"
      log "WARNING:   sudo tailscale up --ssh --hostname=${TS_HOSTNAME:-devaloy}"
    else
      log "WARNING: recover from the Docker host with:"
      log "WARNING:   docker compose exec devaloy tailscale up --ssh"
    fi
  fi
}

# --- native only: bring the node up only when it is not up already ---
#
# On a native VM tailscaled is the package's own systemd unit, and it keeps
# the node identity in /var/lib/tailscale across reboots, so after the first
# install the node rejoins on its own. Running `tailscale up` again on every
# boot and every installer re-run would still work, but it re-sends the auth
# key and rewrites the prefs for nothing. So the native installer and
# devaloy-boot.service ask first, and call step_tailscale_up only when the
# backend is not Running or runs under another hostname (TS_HOSTNAME changed
# in /etc/devaloy/env). The container keeps calling step_tailscale_up
# directly; this function is not part of its boot.
#
# The wait is for a reboot, where devaloy-boot starts right after tailscaled
# and the backend can still be in NoState or Starting for a few seconds. It is
# bounded, and a node that never settles falls through to `up`, which carries
# its own --timeout.
ts_status_field() { # ts_status_field <jq path>
  tailscale --socket="${TS_SOCKET}" status --json 2>/dev/null |
    jq -r "$1 // empty" 2>/dev/null || true
}

ts_is_up_as() { # ts_is_up_as <hostname>
  [ "$(ts_status_field .BackendState)" = "Running" ] &&
    [ "$(ts_status_field .Self.HostName | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ]
}

step_tailscale_ensure() {
  for _ in $(seq 1 30); do
    case "$(ts_status_field .BackendState)" in
      Running|NeedsLogin|NeedsMachineAuth|Stopped) break ;;
    esac
    sleep 1
  done
  if ts_is_up_as "${TS_HOSTNAME:-devaloy}"; then
    log "Tailscale SSH is up as ${TS_HOSTNAME:-devaloy} ($(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1))"
    return 0
  fi
  step_tailscale_up
}
