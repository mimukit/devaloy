# Plan — devaloy: portable remote dev environment (SSH devbox)

Grilled: 2026-07-25
Revised: 2026-07-31 — **merged to a single container on Tailscale SSH.** See
[Revision 2026-07-31](#revision-2026-07-31--tailscale-ssh-single-container).

## Context
**devaloy** is a portable, self-contained Docker Compose stack: a persistent
devbox you SSH into and pick up a coding session from any device — phone or
laptop, on any network. It exists so development itself can happen remotely,
independent of the machine physically in front of you.

The design philosophy is deliberately minimal: **official base image + one
thin, artifact-free Dockerfile, named volumes for persistence.** The stack brings its own tailnet
membership, so it runs on *any* Docker-Compose host —
a cloud VPS, a home server, or a managed panel like Dokploy — without depending
on the host's network or a public IP. Success looks like: SSH into a persistent
[herdr](https://herdr.dev/) session on the devbox, from either the phone or the
laptop, with tools and cloned repos surviving container restarts/redeploys —
reachable only over Tailscale, never on any public IP.

> Origin: extracted from the `brainaloy-dokploy` infra repo so the devbox can be
> maintained as an independent, reusable project rather than one site among that
> panel's WordPress stacks.

## Revision 2026-07-31 — Tailscale SSH, single container

The original design ran `sshd` in a `ubuntu:24.04` devbox alongside a
`tailscale/tailscale` **sidecar**, joined via `network_mode: service:tailscale`,
with key-based auth materialized from a `PUBLIC_KEY` env var. That stack was
built, reviewed, fixed, and is preserved in git history through commit
`fbdb486`.

**What changed:** authentication moves from SSH keys to
[Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh). `tailscaled` runs
*inside* the devbox image, terminates the SSH connection itself, and authorizes
from tailnet identity plus the tailnet policy file. There is no `sshd`, no
`authorized_keys`, no host keys, and no `PUBLIC_KEY`.

**Why the sidecar had to go.** Tailscale SSH spawns the shell on the machine
running `tailscaled`. `network_mode: service:tailscale` shares only the *network*
namespace — filesystems, users and processes stay separate — so a sidecar would
log you into the Alpine sidecar rather than the devbox
([tailscale/tailscale#5215](https://github.com/tailscale/tailscale/issues/5215)).
Merging is not a preference here; it is the only arrangement in which Tailscale
SSH reaches the dev environment.

**The trade-off this reverses — recorded plainly.** The 2026-07-25 grill kept
the sidecar for exactly one reason: it *"keeps `SYS_MODULE` off the container
running untrusted dev code."* That argument is now overridden, and the isolation
it bought is genuinely lost. `NET_ADMIN` and `/dev/net/tun` now sit on the
container that runs arbitrary npm packages and AI coding agents.

Partial mitigation: **`SYS_MODULE` is not granted.** It is only needed to *load*
the `tun` module, so the host is required to have it loaded already
(`modprobe tun`, documented in the README). This costs some of the original
"host-agnostic" promise on a fresh minimal VPS — a host without `tun` preloaded
now needs one manual command. That is a deliberate trade: one documented host
prerequisite in exchange for not handing kernel-module loading to the dev
container.

**Net security position:** weaker container isolation, stronger access control.
No key material exists to leak, rotate, or accidentally truncate — which
retires an entire class of bug this project already hit once (an empty
`PUBLIC_KEY` wiping `authorized_keys`). Access is now revoked centrally from the
tailnet policy file rather than by editing a file on the box.

## Design decisions (settled)

Rows marked **[R2]** were changed by the 2026-07-31 revision.

| Decision | Resolution |
|----------|-----------|
| Purpose | **General-purpose remote dev** (any project). Consequence: the devbox does **not** get access to the host Docker daemon/socket — a casual dev shell shouldn't be able to control the host's other containers. |
| Access method | **SSH only, no browser UI.** [herdr](https://herdr.dev/) inside provides persistent, server-side, reattachable sessions across devices (its core pitch); tmux stays as a tiny fallback. |
| Exposure **[R2]** | **Tailscale-only, single container.** `tailscaled --ssh` runs inside the devbox image. Nothing is published to the host — there is no `ports:` key at all. Reachable only at the container's own tailnet MachineName/IP, on port 22 *within* that namespace. |
| Portability | **Host-agnostic — this is devaloy's defining property.** Runs on any Docker-Compose host. Deployable via plain `docker compose up` *or* a panel like Dokploy. **[R2]** One new host prerequisite: the `tun` module must be loaded (`modprobe tun`), since `SYS_MODULE` is no longer granted. |
| Tailnet access **[R2]** | **`tailscaled` in the devbox container**, installed from Tailscale's official apt repo (pinned to the distro release, no vendored binary). Needs: a reusable, **untagged**, non-expiring `TS_AUTHKEY`; a persisted `/var/lib/tailscale` state volume (so it doesn't register a fresh node each redeploy); `TS_HOSTNAME=devbox`; **`cap_add: [NET_ADMIN]`** + **`devices: [/dev/net/tun]`**. `--accept-dns=false` by default: letting Tailscale rewrite `/etc/resolv.conf` inside a container clobbers Docker's resolver. |
| Auth **[R2]** | **Tailscale SSH — no keys at all.** `tailscaled` terminates the connection and authorizes from tailnet identity plus the tailnet policy file. Requires an `ssh` rule (`action: accept`, `dst: autogroup:self`, `users: ["dev"]`) — deny-by-default, so without it the node joins and still refuses logins. The key must be **untagged** so the node is user-owned and `autogroup:self` matches. A non-root **`dev`** user (fixed UID/GID 1000) with **passwordless sudo** via `/etc/sudoers.d`. |
| Key expiry **[R2]** | **Must be disabled manually** on the node after first registration. A user-owned node key expires (~180 days default) and an expired node is unreachable, recoverable only from the Docker host. This is the design's main standing lockout risk; a tagged node would avoid it but is incompatible with `autogroup:self`. |
| Reachability requirements **[R2]** | **MagicDNS must be enabled** for `ssh dev@devbox` to resolve by name; without it, connect by tailnet IP. **Port 22 is not configurable** — Tailscale SSH hard-codes it. Harmless: that port exists only on the tailnet address inside the container, so it never collides with the host's own sshd. |
| Base image | **`ubuntu:24.04` (LTS, glibc) + one thin Dockerfile.** Chosen because the toolchain (mise-installed node, pnpm, gh, herdr) ships **prebuilt glibc binaries** — musl would cause exactly the prebuilt-binary breakage a general-purpose dev box must avoid. Trade accepted: relax "no build step" to **"one minimal, vendored-artifact-free Dockerfile on an official base."** |
| Init / PID 1 **[R2]** | **Docker-provided tini via compose `init: true`** (zombie reaping — dev shells + herdr spawn many children) → our **entrypoint** wires the shell env, starts `tailscaled`, runs `tailscale up --ssh --timeout=90s`, then does the mise bootstrap, then `wait`s on `tailscaled`. **`--timeout` is load-bearing:** with no authkey and no saved state, `tailscale up` blocks forever on an interactive login URL and the entrypoint never reaches the bootstrap. |
| Boot ordering **[R2]** | **Tailnet first, toolchain second.** The bootstrap takes minutes on a cold volume and there is no `sshd` fallback, so the tailnet must come up *before* it — the box is reachable *during* the install rather than after. Both steps are non-fatal: a failed `tailscale up` or a failed bootstrap logs a warning and lets the container stay alive for diagnosis. |
| Toolchain — apt tier **[R2]** | Installed in the Dockerfile: `sudo git tmux build-essential curl ca-certificates vim htop`, plus `iproute2`/`iptables` (tailscaled) and `openssh-client` (outbound git-over-ssh). `openssh-server` is **gone**. |
| Toolchain — everything else | **mise as the universal installer**, via `bootstrap-toolchain.sh` (single source of truth for the tool list and pins, shared by the entrypoint and `devaloy-update`). herdr is officially mise-installable (`mise use -g herdr` — confirmed, 0.7.5). mise + tools live in the persistent home so they survive redeploys. |
| Non-interactive PATH **[R2]** | **`link-shims` mirrors mise shims into `/usr/local/bin`.** Bash only auto-sources `.bashrc` in a non-interactive shell when stdin is a *socket* — an OpenSSH implementation detail that no longer applies without `sshd`. Without the mirror, `ssh devbox '<cmd>'`, `scp`, `rsync` and git-over-ssh would silently lose the toolchain. `.devaloy_env` (sourced from the **top** of `.bashrc`, above Ubuntu's interactivity guard) still covers interactive shells. |
| Version pins (mise) | **Pin the session-critical + track the stable.** Pin **node** to an LTS major (not mise's floating `lts` alias, which rolls across majors). `gh`/`pnpm`/`turbo` track latest. herdr tracks latest by default but is gated behind a once-per-volume marker so a redeploy can't swap it under a live session; `MISE_HERDR_VERSION` pins it. |
| Toolchain updates | **`devaloy-update`** — clears the marker, re-runs `bootstrap-toolchain.sh`, refreshes the `/usr/local/bin` mirror. Refuses to run as root. The deliberate upgrade path, so boot stays predictable. |
| Resilience / ops **[R2]** | **`restart: unless-stopped`.** `depends_on` is gone with the sidecar. |
| OOM safety | **Host swap + session protection.** No hard `mem_limit` (that would hardcode a host-size assumption). Compose sets `oom_score_adj: -500` so the kernel avoids killing `tailscaled` — losing it severs the only route in. Each shell raises itself back to `0` via `.devaloy_env`, so a runaway build is the preferred victim. Raising is unprivileged; only lowering needs `CAP_SYS_RESOURCE`, which Docker applies itself. |
| Login UX | **Manual herdr, with a hint.** Interactive login prints a one-line reminder (`run: herdr`) rather than auto-attaching — auto-attach breaks `scp`/`sftp`/`rsync`/git-over-ssh. TTY-guarded and appended *after* `.bashrc`'s interactivity guard on purpose. |
| File transfer **[R2]** | **Supported.** Tailscale implements SFTP natively, so `scp`/`sftp` work for modern clients (OpenSSH 9.0+ uses the SFTP protocol for `scp` by default); `rsync` rides on non-interactive command execution. |
| Break-glass **[R2]** | **The Docker host.** With no `sshd` fallback, `docker compose exec devbox tailscale up --ssh` is the only recovery path if the tailnet or the policy file is wrong. Documented in the README and exercised deliberately in QA rather than discovered under pressure. |
| License + metadata | **MIT.** Permissive, ubiquitous for infra/config repos, matches the "reusable standalone project" intent. |
| mosh | **Dropped.** herdr's server-side session persistence + reattach covers the reconnect need; no UDP port range to publish. |
| Persistence **[R2]** | Named volume at **`/home/dev`** — dotfiles, mise + tools, cloned repos. Separate named volume for **`/var/lib/tailscale`** (node identity; losing it forces a re-register). SSH host-key generation is **gone** — Tailscale SSH manages its own host identity. |
| Firewall (host, VPS case) | **`scripts/host-firewall-lockdown.sh`** — default deny incoming, allow outgoing, allow in on `tailscale0`, no 80/443. Two anti-lockout guards: refuses if Tailscale is down, and refuses if the invoking SSH session isn't from a tailnet address (`ALLOW_NON_TAILNET=1` to override). Hardens the *host's own* sshd/mgmt; defense-in-depth, not what protects the devbox. Skippable on a trusted/home host. |
| Backup | **Git-push discipline only.** No backup job, no mandated snapshots. `/home/dev` persists across redeploys; only actual host/volume loss means re-cloning + re-`mise install`. Nothing valuable should live only on the devbox. |

## Approach

**Phase 1 — Author the portable stack** (the core deliverable) — **done**
- `Dockerfile` — `FROM ubuntu:24.04`; apt tier; `tailscaled` from Tailscale's official noble apt repo; `dev` user (UID/GID 1000) + passwordless sudoers drop-in; `COPY` the entrypoint and the three helper scripts; `ENTRYPOINT`. No vendored artifacts, no secrets baked in, no `sshd_config`.
- `entrypoint.sh` — write `.devaloy_env`/`.devaloy_profile` and wire them into `.bashrc`; start `tailscaled`; `tailscale up --ssh --timeout=90s`; mise bootstrap (skip-if-marker, non-fatal); `link-shims`; `wait`.
- `bootstrap-toolchain.sh` / `devaloy-update` / `link-shims` — toolchain install, deliberate refresh, and the `/usr/local/bin` mirror.
- `compose.yml` — one `devbox` service: `build: .`, `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun]`, `init: true`, `oom_score_adj: -500`, `restart: unless-stopped`, `TS_AUTHKEY`/`TS_HOSTNAME`/`TS_ACCEPT_DNS` env, named volumes at `/home/dev` and `/var/lib/tailscale`. **No `ports:`.**
- `.env.example` — documents `TS_AUTHKEY` and the optional overrides. **No `PUBLIC_KEY`.**

**Phase 1b — Tailnet policy file** (new, and a hard prerequisite) — **not started**
- Add an `ssh` rule to the tailnet policy file before first boot. Tailscale SSH is deny-by-default: without it the node joins and logins are still refused.

**Phase 2 — Deploy paths** — **not started**
- **Plain compose (baseline):** `docker compose up -d --build` on any host with Docker and `tun` loaded.
- **Dokploy (optional):** Create → Compose service, set `TS_AUTHKEY`, deploy. The revision **removes `network_mode: service:tailscale`**, which was the specific feature whose Dokploy compatibility was in doubt — this stack may now be strictly easier to deploy there. Unverified.
- Confirm the node appears as `devbox` in the Tailscale admin console, and **disable key expiry on it**.

**Phase 3 — (VPS host only) harden the host** — **not started**
- On a cloud VPS: run `scripts/host-firewall-lockdown.sh` after Tailscale is up on the host. Skippable on a trusted/home Docker host.

**Phase 4 — Connect and verify** — **not started**
- Confirm MagicDNS is enabled (else use the tailnet IP).
- From laptop: `ssh dev@devbox` — no key, no port flag. Start a herdr session.
- From phone (Tailscale app + Terminus): same host, reattach the herdr session.
- Confirm nothing answers on the host's own IP, and that access dies when the policy rule is removed.
- Clone a repo into `/home/dev`, run a `pnpm`/`turbo` build, redeploy, confirm repo + tools + node identity survived.
- Full manual script: `docs/qa/qa-devbox-vps-dryrun-2026-07-31.md`.

**Phase 5 — Document** — **done**
- `README.md`: what devaloy is, the tailnet policy + auth-key setup, `docker compose up`, the connect-from-phone/laptop flow, toolchain updates, break-glass recovery, and the "git-push discipline = your only backup" contract.

## Open questions

- **Terminus (mobile) compatibility with Tailscale SSH** — the highest-risk
  unknown. Tailscale SSH accepts the `none` authentication method and expects the
  client to proceed without offering a key. OpenSSH does; whether Terminus does
  is untested. If it refuses, the merged design fails at its primary use case and
  the fallback is reinstating an `sshd` *alongside* Tailscale SSH — which would
  reintroduce key management for the phone only.
- **Non-interactive PATH under Tailscale SSH specifically** — `link-shims` is
  verified working under `docker exec`, which is the closest available proxy, but
  not under `tailscaled`'s own exec path.
- **Dokploy + this stack** — previously blocked on `network_mode: service:tailscale`;
  that constraint is gone, but nothing has been deployed there yet.
- **Key expiry over time** — the disable-expiry step is a manual admin-console
  toggle with no automated check. Nothing in the stack will warn before a lapse.

_Resolved during grill (2026-07-25):_ base image = `ubuntu:24.04` + thin Dockerfile (glibc, since the toolchain ships prebuilt glibc binaries — LSIO openssh-server is Alpine/musl); PID 1 = tini (`init: true`) + entrypoint; non-root `dev` + passwordless sudo; herdr is mise-installable (`mise use -g herdr`); version pins = pin node + herdr, track latest CLIs; OOM = swap + `oom_score_adj`; login = manual with hint; license = MIT.

_Superseded 2026-07-31:_ the tailscale **sidecar** + `network_mode: service:tailscale`; `TS_USERSPACE=false` and `SYS_MODULE` as reachability requirements; `sshd` + `sshd_config` + `PUBLIC_KEY`→`authorized_keys` key auth; persistent SSH host keys; skeleton-dotfile seeding; port 2222. See [Revision 2026-07-31](#revision-2026-07-31--tailscale-ssh-single-container) for the reasoning, including the isolation trade-off this reverses.

## Non-goals
- No browser-based IDE (code-server) — SSH only.
- No mosh.
- No host Docker socket / Docker-in-Docker — general-purpose dev doesn't warrant handing the box control of the host's containers.
- No public HTTPS domain, no Traefik, no Let's Encrypt.
- No multi-service build sprawl — the Dockerfile stays thin (official base, apt tier, user, entrypoint) with **no vendored artifacts and no baked secrets**.
- No backup tooling for `/home/dev` — git-push discipline is the contract.
- Not tied to a specific host or size — portability is the point.
- No git webhook auto-deploy — manual deploy.
- **No SSH key management, no password auth, and no fallback `sshd`** — Tailscale SSH is the only door.
