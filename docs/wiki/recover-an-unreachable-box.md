# Recover a box you cannot reach

There is no sshd fallback and no published port, by design. When Tailscale SSH
stops answering, **every path back in starts on the Docker host** — so the first
thing to establish is whether you still have access to that host. If you do not,
nothing on this page helps and the box has to be rebuilt from the repo.

Run everything below from the directory holding `docker-compose.yml`.

## First response

```sh
docker compose ps
```

```sh
docker compose logs --tail=100 devaloy
```

The entrypoint prefixes every line with `[entrypoint]` and states each failure
in full. Three lines tell you most of what you need:

| Line | Means |
|---|---|
| `devaloy is up. Connect with: ssh dev@devaloy` | The tailnet came up. The problem is elsewhere. |
| `WARNING: tailscale up failed — this box is NOT reachable over the tailnet.` | Authentication or policy. See below. |
| `WARNING: tailscaled socket never appeared` | The host is missing `tun`, or the container lost `NET_ADMIN`. |

Then check what Tailscale itself thinks:

```sh
docker compose exec devaloy tailscale status
```

## Symptom table

| Symptom | Cause | Fix |
|---|---|---|
| Container is not running at all | Crash, or the host rebooted without `restart: unless-stopped` taking effect | `docker compose up -d` |
| `failed to create TUN device`, or the socket never appeared | Host is missing the `tun` module | [Load `tun`](#the-host-is-missing-tun) |
| Node missing from the admin console | `TS_AUTHKEY` empty, expired, or already consumed | [Re-authenticate](#the-node-never-joined) |
| Node listed but shows **Expired** | Node key expiry, ~180 days by default | [Re-authenticate](#the-node-key-expired) |
| Node reachable, SSH refused | No matching rule in the tailnet policy file | [Fix the policy file](#ssh-is-refused) |
| Node reachable, `dev` login rejected | Policy rule's `users` list omits `dev` | Add `"users": ["dev"]` |
| Reachable, but `pnpm`/`gh`/`claude` are missing | Toolchain bootstrap failed | [Re-run the bootstrap](#the-toolchain-never-installed) |
| `ssh devaloy '<cmd>'` cannot find a tool an interactive shell finds | `link-shims` did not run | `devaloy update` as `dev` — see below |

## The host is missing `tun`

`tailscaled` cannot create its interface without the kernel module, and the
container is deliberately not granted `SYS_MODULE` so it cannot load it itself.

```sh
sudo modprobe tun
```

```sh
docker compose up -d
```

Persist it across host reboots:

```sh
echo tun | sudo tee /etc/modules-load.d/tun.conf
```

If `/dev/net/tun` exists on the host but the container still fails, confirm
`cap_add: NET_ADMIN` and the `/dev/net/tun` device mapping are both still in
`docker-compose.yml`.

## The node never joined

`tailscale up` failing is **deliberately non-fatal** — restart-looping would not
fix a bad auth key or a missing ACL rule, and it would destroy the one
diagnostic path you have left. The container stays up so you can read the log.

If `TS_AUTHKEY` was empty, `tailscaled` printed a login URL further up the log:

```sh
docker compose logs devaloy | grep -i 'to authenticate'
```

Open that URL, or set a proper key and redeploy. The key must be **reusable,
non-expiring and untagged** — a tagged key breaks the `autogroup:self` rule that
the policy file relies on.

Either way, this is the command that finishes the job from the host:

```sh
docker compose exec devaloy tailscale up --ssh
```

Note that `tailscale up` blocks forever when it has no key and no saved state,
which is why the entrypoint passes `--timeout=90s`. Running it by hand as above
has no timeout, so it will sit there printing a URL — that is what you want here.

## The node key expired

A user-owned node key expires around 180 days out, and an expired node is
unreachable. Re-authenticate from the host:

```sh
docker compose exec devaloy tailscale up --ssh
```

Then **disable key expiry** on the node in the
[admin console](https://login.tailscale.com/admin/machines) so it cannot happen
again. Doing this on day one is step 7 of
[Getting started](getting-started.md#7-disable-key-expiry-on-the-node) for
exactly this reason.

## SSH is refused

The node is reachable but the connection is rejected. Tailscale SSH is
deny-by-default: joining the tailnet grants nothing on its own. Your
[policy file](https://login.tailscale.com/admin/acls) needs a rule allowing
`dev`:

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

Policy changes take effect without redeploying anything.

If the rule is present and login still fails, check the auth key was untagged —
`autogroup:self` matches devices owned by the same user, and a tagged node is
owned by the tag, not by you.

## The toolchain never installed

You can log in, but `pnpm`, `gh`, `claude` or `codex` are missing. The bootstrap
is non-fatal on purpose: a network blip on first boot must not cost you the box.
The revision marker is only written on success, so the fix is simply to re-run
it — on the box, as `dev`:

```sh
devaloy update
```

That runs `bootstrap-toolchain.sh --force`, which skips the toolset gate,
re-resolves everything tracking `latest`, reinstalls the agent skills, and
refreshes the `/usr/local/bin` mirror.

A failed **skills** install alone will also land you here: it is allowed to be
fatal, so the marker is never written and the whole bootstrap retries on the
next boot. That is intended — a skills outage costs a retry, never your tailnet.

## Non-interactive commands cannot find the toolchain

`ssh devaloy 'pnpm build'`, `scp`, `rsync` and git-over-ssh do not reliably
source `~/.bashrc`, so they see only the default `PATH`. `link-shims` mirrors
mise's shims into `/usr/local/bin` to cover that. If it failed, the log says so:

```
WARNING: link-shims failed — non-interactive commands may not find the toolchain.
```

Re-run it from the box:

```sh
devaloy update
```

Run this after any `npm i -g` too — a globally installed binary is invisible to
non-interactive sessions until the mirror is refreshed.

## Last resort: recreate the container

`/home/dev`, the Tailscale node identity, and the nested Docker daemon's data
are all named volumes, so recreating the container keeps your repos,
credentials, node key, and nested images:

```sh
docker compose down && docker compose up -d --build
```

**Never `docker compose down -v` to fix a connectivity problem.** That deletes
all three volumes: every clone, every credential, the nested Docker data, and
the node identity, so the box
rejoins the tailnet as a brand new machine. Unpushed work is gone — there is no
backup job and no snapshot on this stack.

## Things that look broken and are not

- **`Failed to connect to the bus`** in the log — there is no session bus in the
  container. Harmless.
- **No mention of Orca at all** — silence is correct on a stock build.
  `WITH_ORCA=false` is the default, so a missing `/usr/bin/orca-ide` is the
  normal case, not a fault.
- **`gh auth login` refuses to run** — expected while `GITHUB_TOKEN` is set. The
  environment would outrank a stored credential anyway.
- **`[autoUpdater] Checking for update`** from Orca — it cannot apply anything;
  `/opt` is root-owned and the server runs as `dev`.

## See also

- [Getting started](getting-started.md) — the setup steps these failures map back to.
- [Architecture](architecture.md) — the boot order that decides which failures
  are survivable.
- [Deploy with Dokploy](deploy-with-dokploy.md#troubleshooting) — the same
  failures as they appear through a Dokploy panel.

_Verified against `main`@`b6bc42b` on 2026-08-25._
