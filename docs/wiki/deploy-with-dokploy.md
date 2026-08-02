# Deploying devaloy with Dokploy

This walks through running the devbox as a [Dokploy](https://dokploy.com/)
**Compose** service, deployed straight from this GitHub repo. It assumes you
already have a Dokploy server running.

Dokploy changes very little about how this stack works. It clones the repo,
writes an `.env` next to the compose file, and runs
`docker compose -p <service-name> up -d --build` for you. Everything the
[README](../../README.md) says about Tailscale, the home volume and the
toolchain still holds — what Dokploy adds is a UI for the env vars, a redeploy
button, a webhook, and volume backups.

What Dokploy does *not* add: a domain, a Traefik route, or a published port.
This devbox has no HTTP surface and nothing to expose. You will leave the
**Domains** tab empty, and that is correct rather than an unfinished step.

## 1. Prepare the Dokploy host

Pick which server the service runs on first (Dokploy can manage remote
servers) — every prerequisite below applies to *that* host, not the panel.

### The `tun` module

The container needs `/dev/net/tun` on the host. Check and load it:

```sh
ls -l /dev/net/tun || sudo modprobe tun
```

Make it survive a reboot, or the next time the VPS restarts the devbox will
come back up with no tailnet and no way in:

```sh
echo tun | sudo tee /etc/modules-load.d/tun.conf
```

`SYS_MODULE` is deliberately not granted to the container, so it cannot load
the module itself — see the README for why.

### Tailnet policy file and auth key

Do these in the Tailscale admin console before deploying; they are unchanged by
Dokploy, so follow [README → One-time setup](../../README.md#one-time-setup)
steps 2 and 3. You need:

- an `ssh` rule in the policy file granting `autogroup:member` → `autogroup:self`
  as user `dev`
- a **reusable, non-expiring, untagged** auth key

Have the auth key on your clipboard for step 3.

## 2. Create the Compose service

In Dokploy: open (or create) a **Project** → **Create Service** → **Compose**.

| Field | Value | Why |
|---|---|---|
| Name | `devaloy` (or anything) | Becomes the compose project name and the volume prefix. Changing it later orphans your volumes. |
| Source Type | **GitHub** | Gives you the auto-deploy webhook. Use **Custom Git** with a deploy key if you'd rather not install the GitHub App; use **Raw** only if you paste `compose.yml` and drop `build:` for a prebuilt image. |
| Repository | `mimukit/devaloy` | Private repos need the Dokploy GitHub App installed on the repo. |
| Branch | `main` | |
| Compose Path | `./compose.yml` | **Not** the `./docker-compose.yml` default — this repo uses the modern filename. |
| Compose Type | **Docker Compose** | Must not be **Stack**. Swarm ignores `devices:` and `cap_add:`, so `tailscaled` would come up with no `tun` and no `NET_ADMIN`, and `build:` is unsupported there too. |

Save.

### The custom compose path caveat

Dokploy passes `-f ./compose.yml` on **Deploy** and **Redeploy**, but a
[known bug](https://github.com/Dokploy/dokploy/issues/2282) means the UI's
**Stop** → **Start** buttons drop the `-f` flag and look for
`docker-compose.yml`, which does not exist here. Two ways around it:

- **Just use Redeploy** instead of Stop → Start. Simplest, nothing to change.
- **Add a symlink** in the repo root so both filenames resolve:
  `ln -s compose.yml docker-compose.yml && git add docker-compose.yml`

## 3. Environment variables

Open the service's **Environment** tab and paste:

```sh
TS_AUTHKEY=tskey-auth-...
GITHUB_TOKEN=ghp_...
```

Dokploy writes these to an `.env` file beside the checked-out compose file, and
`compose.yml` already reads them via `${TS_AUTHKEY}` / `${GITHUB_TOKEN}`
interpolation — so there is nothing to add to the compose file itself, and no
`env_file:` needed.

`GITHUB_TOKEN` is optional; see
[README → GitHub token](../../README.md#4-optional-github-token) for what it
buys you and what it costs (a live credential lands in the home volume).
`TS_HOSTNAME`, `TS_ACCEPT_DNS`, `MISE_NODE_VERSION` and `MISE_HERDR_VERSION`
are optional overrides and can go here too.

Treat this tab as the secret store: the auth key is non-expiring and never
belongs in git. `.env` is gitignored in this repo for the same reason.

## 4. Deploy

Hit **Deploy**. The first build pulls `ubuntu:24.04` and installs the apt layer,
so give it a few minutes. Watch the **Logs** tab for `[entrypoint]` lines.

The tailnet comes up *before* the toolchain install, so the node appears in the
[admin console](https://login.tailscale.com/admin/machines) well before the box
is fully provisioned. A cold home volume then spends several more minutes in
`mise` pulling node, Claude Code and Codex — you can log in and watch it rather
than waiting.

Once the node shows up: **disable key expiry on it.** A user-owned node key
expires in roughly 180 days, and an expired node is unreachable — recovering it
means getting back to the Docker host.

Then, from any device on your tailnet:

```sh
ssh dev@devbox
herdr
```

## 5. Auto-deploy: turn it off

Dokploy offers **Auto Deploy** on push. Leave it **disabled** for this service.

A redeploy rebuilds the image and recreates the container, which kills every
running process — including the `herdr` server holding your session. Your files
in `/home/dev` survive; the session you were mid-way through does not. An
auto-deploy triggered by a README typo while you are working from a phone is a
bad trade for a devbox.

Deploy on purpose instead, when you know nothing is attached.

## 6. Day-2 operations

**Updating the toolchain.** Unchanged by Dokploy — the toolchain installs once
per home volume, so a redeploy never swaps tools out from under a live session.
To pick up newer versions, SSH in and run `devaloy-update`. Adding a tool to
`bootstrap-toolchain.sh` also requires bumping `TOOLSET_REVISION` in that file,
or a provisioned box will keep skipping the bootstrap.

**Changing shell or agent config.** Edit under `config/` in this repo, push, and
**Redeploy**. The entrypoint copies `config/` over `/home/dev` on every boot, so
the repo wins — that is the whole point of config-as-code here.

**Break-glass.** If the box drops off the tailnet, go through Dokploy's
**Terminal** (or SSH to the host) and run:

```sh
docker exec -it devaloy-devbox tailscale status
docker exec -it devaloy-devbox tailscale up --ssh
```

There is no sshd fallback by design.

## 7. Volumes and backups

Dokploy prefixes the compose project name onto the named volumes, so with a
service named `devaloy` you get:

| Volume | Holds | Losing it means |
|---|---|---|
| `devaloy_devbox-home` | `/home/dev` — repos, toolchain, agent credentials, GitHub token | Re-clone and re-provision |
| `devaloy_tailscale-state` | The node's identity | The box rejoins as a *new* machine and needs a fresh auth key |

Both are Docker named volumes, so Dokploy's **Volume Backups** feature works on
them. It is worth enabling on `devaloy_tailscale-state` — it is tiny and it is
the difference between a redeploy and a re-enrollment.

**Deleting the service in Dokploy can delete these volumes.** Read the
confirmation dialog. The README's backup contract still applies regardless:
git-push discipline is the only real backup, and nothing valuable should live
only on the devbox.

## 8. Do not run the host firewall script

`scripts/host-firewall-lockdown.sh` sets `ufw default deny incoming` and allows
traffic only on `tailscale0`. On a plain VPS that is sensible defense-in-depth.
**On a Dokploy host it will cut off Dokploy itself** — the panel on port 3000
and Traefik on 80/443 all become unreachable from the public internet, taking
every other site on that server with them.

Only run it if the Dokploy host exists solely for this devbox *and* you want to
reach the panel over the tailnet only. Otherwise skip it: the devbox publishes
no ports and needs no host firewall rule to stay private.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no such file or directory: docker-compose.yml` | Compose Path not set, or the Stop→Start bug | Set Compose Path to `./compose.yml`; use Redeploy, or add the symlink |
| Node never appears in the admin console | `TS_AUTHKEY` empty or expired | Check the Environment tab actually saved; `compose.yml` defaults it to empty and `tailscaled` starts unauthenticated |
| `Warning: TS_AUTHKEY variable is not set` in build logs | Dokploy's `.env` landed beside the wrong file ([#2777](https://github.com/Dokploy/dokploy/issues/2777)) | Confirm the Environment tab is saved and redeploy; verify with `docker exec devaloy-devbox printenv TS_AUTHKEY` |
| `failed to create TUN device` | Host missing `tun` | `sudo modprobe tun`, then persist via `/etc/modules-load.d/tun.conf` |
| Tailnet up, but SSH is refused | Policy file has no matching `ssh` rule, or the auth key was tagged | Untagged key + the `autogroup:self` rule (README step 2) |
| Node reachable, `dev` login rejected | `users` list in the policy rule omits `dev` | Add `"users": ["dev"]` |
| `gh auth login` refuses to run | `GITHUB_TOKEN` is set — expected, not a fault | Clear it in the Environment tab and redeploy to use the interactive flow |
| Session vanished after a deploy | Redeploy recreated the container | Expected. Disable Auto Deploy (§5) |

## Sources

- [Dokploy — Docker Compose](https://docs.dokploy.com/docs/core/docker-compose)
- [Dokploy — Environment Variables](https://docs.dokploy.com/docs/core/variables)
- [Dokploy — Volume Backups](https://docs.dokploy.com/docs/core/volume-backups)
- [Dokploy issue #2282 — custom Compose Path ignored on Stop/Start](https://github.com/Dokploy/dokploy/issues/2282)
- [Dokploy issue #2777 — env vars not loaded in Compose](https://github.com/Dokploy/dokploy/issues/2777)
