# devaloy

A portable, self-contained Docker Compose devbox you SSH into and pick up a
coding session from any device — phone or laptop, on any network. It exists so
development itself can happen remotely, independent of the machine physically in
front of you.

Reachable **only** through [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh),
never on any public IP and never on any published port. There are no SSH keys to
manage: `tailscaled` terminates the connection itself and authorizes you from
your tailnet identity plus your tailnet policy file. Tools and cloned repos
survive container restarts and redeploys.

## How it works

- One container: `ubuntu:24.04` running `tailscaled` with `--ssh`, plus a single
  non-root `dev` user with passwordless sudo.
- **No sshd, no `authorized_keys`, no host keys.** Tailscale SSH claims port 22
  on the tailnet address only, inside the container's own network namespace.
  Nothing is published to the Docker host.
- `tailscaled` runs *inside* this image rather than as a sidecar on purpose.
  Tailscale SSH spawns the shell in whichever container runs the daemon, so a
  sidecar sharing only the network namespace would log you into the sidecar
  ([tailscale/tailscale#5215](https://github.com/tailscale/tailscale/issues/5215)).
- [herdr](https://herdr.dev/) gives you a persistent, reattachable terminal
  session across devices — start it once, reattach from anywhere.
- `mise` installs and pins the rest of the toolchain (node, pnpm, gh, turbo,
  herdr) into the persistent home volume.

## One-time setup

### 1. Host prerequisite

The container needs the `tun` module on the Docker host. Most hosts already have
it; load it if `/dev/net/tun` is missing:

```sh
sudo modprobe tun
```

`SYS_MODULE` is deliberately not granted to the container — it would let a
process inside load kernel modules, which is close to a container escape on a
box that runs arbitrary dev code and AI agents.

### 2. Tailnet policy file

Tailscale SSH is deny-by-default: without a rule you can join the tailnet and
still not be able to log in. Add this to the `ssh` section of your
[policy file](https://login.tailscale.com/admin/acls):

```json
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["dev"]
    }
  ]
}
```

`autogroup:self` means "devices owned by the same user as the connecting
device", which is why the auth key below must be **untagged**. Use `"action":
"check"` instead of `"accept"` if you want periodic browser re-authentication —
be aware that is painful from a phone.

### 3. Auth key

Generate a **reusable, non-expiring, untagged** key:
https://login.tailscale.com/admin/settings/keys

Then copy `.env.example` to `.env` and set `TS_AUTHKEY`:

```sh
cp .env.example .env
```

### 4. Start the stack

```sh
docker compose up -d --build
```

### 5. Disable key expiry

Once the node appears in the
[admin console](https://login.tailscale.com/admin/machines), **disable key
expiry on it**. A user-owned node key expires (~180 days by default), and an
expired node is unreachable — recovering it needs access to the Docker host.

## Connecting

From any device on your tailnet (laptop, or phone with the Tailscale app):

```sh
ssh dev@devbox
```

No key, no port flag, no password. Tailscale SSH assumes port 22 and there is
no way to change it — but that port only exists on the tailnet address inside
the container, so it never collides with the host's own sshd.

If MagicDNS is off, use the node's `100.x.y.z` address instead of `devbox`.

Then start (or reattach) your session:

```sh
herdr
```

Detach and reconnect from a different device — the session picks up where you
left off.

## Updating the toolchain

The toolchain installs once per volume, so redeploys are predictable and never
swap a tool out from under a live session. To pick up newer versions or a
changed pin, run this on the devbox as `dev`:

```sh
devaloy-update
```

Pins live in `bootstrap-toolchain.sh`. Node is pinned to an LTS major; `gh`,
`pnpm` and `turbo` track latest. To pin herdr too, set `MISE_HERDR_VERSION` in
your `.env` and re-run `devaloy-update`.

`devaloy-update` also refreshes `/usr/local/bin`, which is what makes the
toolchain visible to non-interactive sessions (`ssh devbox '<cmd>'`, `scp`,
`rsync`, git-over-ssh). Run it after any `npm i -g`.

## Recovering a box you can't reach

There is no sshd fallback by design, so the break-glass path is the Docker host:

```sh
docker compose exec devbox tailscale status
```

```sh
docker compose exec devbox tailscale up --ssh
```

## (Optional) hardening the host

On a cloud VPS, `scripts/host-firewall-lockdown.sh` locks down the *host's* own
firewall (deny incoming by default, allow only on the `tailscale0` interface) as
defense-in-depth. It refuses to run unless Tailscale is already up, to avoid
locking you out. This protects the host, not the devbox — the devbox already
publishes nothing. Skip it on a trusted/home Docker host.

```sh
sudo scripts/host-firewall-lockdown.sh
```

## Backup contract

There is no backup job and no snapshot tooling. `/home/dev` persists across
redeploys, but **git-push discipline is the only backup**: nothing valuable
should live only on the devbox. If the host or its volumes are lost, recovery is
re-cloning your repos and re-running `mise install`.

## Non-goals

- No browser-based IDE — SSH only.
- No mosh — herdr's reattach covers the reconnect case.
- No host Docker socket access — the devbox can't control the host's other
  containers.
- No public HTTPS domain, no Traefik, no Let's Encrypt.
- No SSH key management, no password auth, no fallback sshd.
