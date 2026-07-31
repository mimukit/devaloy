# devaloy

A portable, self-contained Docker Compose stack: a persistent devbox you SSH
into and pick up a coding session from any device — phone or laptop, on any
network. It exists so development itself can happen remotely, independent of
the machine physically in front of you.

Reachable only over your [Tailscale](https://tailscale.com/) tailnet, never on
any public IP. Tools and cloned repos survive container restarts and
redeploys.

## How it works

- A `tailscale` sidecar container joins your tailnet. The `devbox` container
  shares its network namespace (`network_mode: service:tailscale`) — nothing
  is ever published to the host.
- `devbox` is `ubuntu:24.04` + `sshd`, key-only auth, a single non-root `dev`
  user with passwordless sudo.
- [herdr](https://herdr.dev/) gives you a persistent, reattachable terminal
  session across devices — start it once, reattach from anywhere.
- `mise` installs and pins the rest of the toolchain (node, pnpm, gh, turbo,
  herdr) into the persistent home volume.

## One-time setup

1. Generate a reusable, non-expiring Tailscale auth key (tag it, e.g.
   `tag:devbox`): https://login.tailscale.com/admin/settings/keys
2. Copy `.env.example` to `.env` and fill in:
   - `TS_AUTHKEY` — the key from step 1.
   - `PUBLIC_KEY` — your SSH public key(s), one per line (e.g. laptop +
     phone), for the devices you'll connect from.
3. Start the stack:

   ```sh
   docker compose up -d --build
   ```

4. Confirm the sidecar shows up as `devbox` in the
   [Tailscale admin console](https://login.tailscale.com/admin/machines).
5. If your tailnet doesn't have MagicDNS enabled, either enable it or connect
   using the sidecar's tailnet IP instead of the `devbox` name.

## Connecting

From any device on your tailnet (laptop, or phone with the Tailscale app):

```sh
ssh -p 2222 dev@devbox
```

Then start (or reattach) your session:

```sh
herdr
```

Detach and reconnect from a different device — the session picks up where
you left off.

## (Optional) hardening the host

On a cloud VPS, `scripts/host-firewall-lockdown.sh` locks down the *host's*
own firewall (deny incoming by default, allow only on the `tailscale0`
interface) as defense-in-depth. It refuses to run unless Tailscale is already
up, to avoid locking you out. Skip this on a trusted/home Docker host.

```sh
sudo scripts/host-firewall-lockdown.sh
```

## Backup contract

There is no backup job and no snapshot tooling. `/home/dev` persists across
redeploys, but **git-push discipline is the only backup**: nothing valuable
should live only on the devbox. If the host or its volumes are lost, recovery
is re-cloning your repos and re-running `mise install`.

## Non-goals

- No browser-based IDE — SSH only.
- No mosh — herdr's reattach covers the reconnect case.
- No host Docker socket access — the devbox can't control the host's other
  containers.
- No public HTTPS domain, no Traefik, no Let's Encrypt.
