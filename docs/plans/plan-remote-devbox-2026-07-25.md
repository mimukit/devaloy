# Plan — devaloy: portable remote dev environment (SSH devbox)

Grilled: 2026-07-25

## Context
**devaloy** is a portable, self-contained Docker Compose stack: a persistent
devbox you SSH into and pick up a coding session from any device — phone or
laptop, on any network. It exists so development itself can happen remotely,
independent of the machine physically in front of you.

The design philosophy is deliberately minimal: **official base image + one
thin, artifact-free Dockerfile, named volumes for persistence.** The stack brings its own tailnet
membership via a Tailscale sidecar, so it runs on *any* Docker-Compose host —
a cloud VPS, a home server, or a managed panel like Dokploy — without depending
on the host's network or a public IP. Success looks like: SSH into a persistent
[herdr](https://herdr.dev/) session on the devbox, from either the phone or the
laptop, with tools and cloned repos surviving container restarts/redeploys —
reachable only over Tailscale, never on any public IP.

> Origin: extracted from the `brainaloy-dokploy` infra repo so the devbox can be
> maintained as an independent, reusable project rather than one site among that
> panel's WordPress stacks.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Purpose | **General-purpose remote dev** (any project). Consequence: the devbox does **not** get access to the host Docker daemon/socket — a casual dev shell shouldn't be able to control the host's other containers. |
| Access method | **SSH only, no browser UI.** [herdr](https://herdr.dev/) inside provides persistent, server-side, reattachable sessions across devices (its core pitch); tmux stays as a tiny fallback. |
| Exposure | **Tailscale-only, via a sidecar.** Nothing is published to the host; the devbox is reachable only at its own tailnet MachineName/IP. |
| Portability | **Host-agnostic — this is devaloy's defining property.** Runs on any Docker-Compose host. Deployable via plain `docker compose up` *or* a panel like Dokploy. No assumptions about host size (add swap on the host for build spikes). |
| Tailnet access | **Tailscale sidecar container** with its own tailnet node; the devbox uses `network_mode: service:tailscale` so its `sshd` binds only to the sidecar's tailnet IP. **No host port published → no public-IP exposure, and the "Docker `-p` bypasses `ufw`" hazard never arises.** Sidecar needs: a reusable `TS_AUTHKEY` (tagged e.g. `tag:devbox`, non-expiring), a persisted `/var/lib/tailscale` state volume (so it doesn't register a fresh node each redeploy), `TS_HOSTNAME=devbox`, and **`TS_USERSPACE=false`** — kernel networking. Kernel mode requires **`cap_add: [NET_ADMIN, SYS_MODULE]` + `devices: [/dev/net/tun]`**: `NET_ADMIN` + the TUN device give the shared namespace a usable tailnet IP, and **`SYS_MODULE` lets the sidecar load `xt_mark`/`nf_nat`** on hosts that don't preload them — without it kernel mode half-works (ICMP up, TCP/SSH dead) on a fresh minimal VPS, defeating the host-agnostic promise. Userspace mode won't give the namespace a usable tailnet IP at all. |
| Reachability requirements | **MagicDNS must be enabled** on the tailnet for `ssh -p 2222 <user>@devbox` to resolve by name; without it, connect by the sidecar's tailnet IP. One-time admin-console setting, documented in setup. |
| Base image | **`ubuntu:24.04` (LTS, glibc) + one thin Dockerfile.** Chosen over `linuxserver/openssh-server` because that image is **Alpine/musl**, and the toolchain (mise-installed node, pnpm, gh, herdr) ships **prebuilt glibc binaries** — musl would cause exactly the prebuilt-binary breakage a general-purpose dev box must avoid. Trade accepted: relax "no build step" to **"one minimal, vendored-artifact-free Dockerfile on an official base."** The Dockerfile is ~15 lines and is *simpler to reason about* than the LSIO s6/`DOCKER_MODS` machinery it replaces. We now own sshd, the user, sudo, init, and host keys (rows below). |
| Init / PID 1 | **Docker-provided tini via compose `init: true`** (zombie reaping — dev shells + herdr spawn many children) → our **entrypoint** does idempotent first-boot setup (materialize `authorized_keys`, generate/persist host keys, mise bootstrap) then `exec /usr/sbin/sshd -D`. No s6, no supervisor to author. |
| Auth | **Key-only, our own convention preserved.** The `PUBLIC_KEY` env (newline-separated for phone + laptop keys) is materialized into the dev user's `~/.ssh/authorized_keys` by the entrypoint at each boot. `sshd_config`: `PasswordAuthentication no`, `PermitRootLogin no`, pubkey only. A non-root **`dev`** user (fixed UID/GID 1000) with **passwordless sudo** via `/etc/sudoers.d` so ad hoc installs don't need a redeploy. |
| Toolchain — apt tier | Installed in the Dockerfile via `RUN apt-get install`: `openssh-server sudo git tmux build-essential curl ca-certificates vim htop`. |
| Toolchain — everything else | **mise as the universal installer.** The entrypoint bootstraps mise; mise then installs the app list. **herdr is officially mise-installable** (`mise use -g herdr` — confirmed backend), so no `install.sh` fallback is needed for it. The "array of apps to extend later" = a single mise config. mise + its installed tools live in the persistent home so they survive redeploys and the bootstrap is idempotent (skip-if-present). We own the `dev` user, so ownership is clean (no post-hoc `chown` dance); the user's `~/.bashrc`/`~/.profile` activates mise on login. |
| Version pins (mise) | **Pin the session-critical + track the stable.** Pin **node** to an LTS major and pin **herdr** to a specific version (pre-1.0, multiple stable releases/month — an unpinned redeploy could pull a breaking herdr under a live session). Let **gh / pnpm / turbo track latest** (mature, backward-compatible, low blast radius). Bump herdr's pin deliberately, not by accident of redeploy. |
| Resilience / ops | **`restart: unless-stopped` on both services** (survive host reboot — the whole "persistent devbox" promise) and **`depends_on: [tailscale]` on the devbox** (the shared namespace must exist before the devbox joins). |
| OOM safety | **Host swap + session protection.** Keep "add swap on the host" as the primary answer (no hard `mem_limit` — that would hardcode a host-size assumption). Additionally set `oom_score_adj` so the kernel prefers killing a runaway build over `tailscaled`/`sshd`/the herdr session, so a bad build on a tiny box doesn't sever the connection you'd need to recover. |
| Login UX | **Manual herdr, with a hint.** Interactive login prints a one-line reminder (`run: herdr`) rather than auto-attaching — auto-attach can break `scp`/`sftp`/`rsync`/git-over-ssh. If auto-attach is ever added it must be strictly TTY-guarded. |
| License + metadata | **MIT.** Permissive, ubiquitous for infra/config repos, matches the "reusable standalone project" intent. Add a one-line description + topics when the repo goes public. |
| mosh | **Dropped.** herdr's server-side session persistence + reattach covers the reconnect need; no UDP port range to publish. |
| Persistence | Named volume mounted at the dev user's home (**`/home/dev`**) — dotfiles, mise + tools, and cloned repos. **SSH host keys** are generated by the entrypoint into the persistent home on first boot (absent-only) and referenced by `sshd_config`, so identity is stable across redeploys *and* image rebuilds (no client MITM warnings) — strictly better than baking them into the image. Entrypoint seeds skeleton dotfiles if the volume is empty (the empty-volume-shadows-home case). Separate named volume for `/var/lib/tailscale` sidecar state. |
| Firewall (host, VPS case) | **`scripts/host-firewall-lockdown.sh`** — default deny incoming, allow outgoing, allow in on `tailscale0`, no 80/443. Anti-lockout guard: refuses to run if Tailscale is down. Hardens the *host's own* `sshd`/mgmt; defense-in-depth, not what protects the devbox (the sidecar already exposes nothing on the host). Skippable on a trusted/home host. |
| Backup | **Git-push discipline only.** No backup job, no mandated snapshots. `/home/dev` persists across redeploys; only actual host/volume loss means re-cloning + re-`mise install`. Nothing valuable should live only on the devbox. |

## Approach

**Phase 1 — Author the portable stack** (the core deliverable)
- `Dockerfile` (at repo root) — `FROM ubuntu:24.04`; `apt-get install` the apt tier (`openssh-server sudo git tmux build-essential curl ca-certificates vim htop`); create the `dev` user (UID/GID 1000) + passwordless sudoers drop-in; write a key-only `sshd_config` (`PasswordAuthentication no`, `PermitRootLogin no`, `HostKey` pointed at the persistent home); `COPY` the entrypoint; `ENTRYPOINT`. No vendored artifacts, no secrets baked in.
- `entrypoint.sh` — idempotent first-boot: materialize `~/.ssh/authorized_keys` from `PUBLIC_KEY`; generate SSH **host** keys into the persistent home if absent; seed skeleton dotfiles if the home volume is empty; bootstrap mise + install the pinned app list (skip-if-present); wire mise activation + the `run: herdr` login hint into the dev user's shell profile; then `exec /usr/sbin/sshd -D`.
- `compose.yml` (at the repo root — devaloy *is* the stack, not a template):
  - `tailscale` sidecar service — `tailscale/tailscale` image, `TS_AUTHKEY`/`TS_STATE_DIR=/var/lib/tailscale`/`TS_HOSTNAME=devbox`/**`TS_USERSPACE=false`**, **`cap_add: [NET_ADMIN, SYS_MODULE]`**, `devices: [/dev/net/tun]`, `restart: unless-stopped`, named state volume.
  - `devbox` service — **`build: .`** (the Dockerfile above), `network_mode: service:tailscale`, **`depends_on: [tailscale]`**, **`restart: unless-stopped`**, **`init: true`** (tini for zombie reaping), **`oom_score_adj` biased toward killing builds over sshd/session**, `PUBLIC_KEY` env, named volume at `/home/dev`. (No `ports:` — `network_mode: service:` forbids it; port 2222 listens inside the shared tailnet namespace only.)
- `.env.example` — documents `TS_AUTHKEY` and `PUBLIC_KEY` (both set manually; no auto-generation).

**Phase 2 — Deploy paths**
- **Plain compose (baseline):** `docker compose up -d --build` on any host with Docker (the `--build` builds the devbox image from the Dockerfile).
- **Dokploy (optional):** Create → Compose service, set `TS_AUTHKEY` + `PUBLIC_KEY`, deploy (Dokploy builds the `build: .` image). Verify `network_mode: service:tailscale` + Isolated Deployments coexist (the devbox joins the sidecar's namespace, not the isolated network — the sidecar handles outbound); disable isolation for this stack if they conflict.
- Confirm the sidecar appears as `devbox` in the Tailscale admin console.

**Phase 3 — (VPS host only) harden the host**
- On a cloud VPS: run `scripts/host-firewall-lockdown.sh` after Tailscale is up. Skippable on a trusted/home Docker host.

**Phase 4 — Connect and verify**
- Confirm MagicDNS is enabled in the tailnet (else use the sidecar's tailnet IP).
- From laptop: `ssh -p 2222 <user>@devbox` (tailnet name), confirm key auth, start a herdr session.
- From phone (Tailscale app installed): SSH client → same host → reattach the herdr session.
- Confirm no host public IP answers on the SSH port (sidecar means there's nothing to answer).
- Clone a repo into `/home/dev`, run a `pnpm`/`turbo` build to sanity-check the toolchain, redeploy the stack, confirm repo + tools survived.

**Phase 5 — Document**
- `README.md`: what devaloy is, the one-time Tailscale auth-key + `PUBLIC_KEY` setup, `docker compose up`, and the connect-from-phone/laptop flow. State the "git-push discipline = your only backup" contract plainly.

## Open questions
- **Dokploy + `network_mode: service:tailscale` compatibility** — verify at deploy time that Isolated Deployments doesn't fight the shared-namespace setup; disable isolation for this stack if it does. (Deploy-time verification, not a design blocker — plain `docker compose up` is the baseline either way.)

_Resolved during grill (2026-07-25):_ base image = `ubuntu:24.04` + thin Dockerfile (glibc, since the toolchain ships prebuilt glibc binaries — LSIO openssh-server is Alpine/musl); tailscale stays a **sidecar** (keeps `SYS_MODULE` off the container running untrusted dev code — the one argument that survives now that the Dockerfile removed the s6-authoring objection); PID 1 = tini (`init: true`) + entrypoint `exec sshd -D`; auth = `PUBLIC_KEY`→`authorized_keys` in entrypoint, key-only sshd, non-root `dev` + passwordless sudo; host keys generated into persistent home; herdr is mise-installable (`mise use -g herdr`); `TS_USERSPACE=false` + `SYS_MODULE` required for kernel-mode reachability; version pins = pin node + herdr, track latest CLIs; OOM = swap + `oom_score_adj`; login = manual with hint; license = MIT.

## Non-goals
- No browser-based IDE (code-server) — SSH only.
- No mosh.
- No host Docker socket / Docker-in-Docker — general-purpose dev doesn't warrant handing the box control of the host's containers.
- No public HTTPS domain, no Traefik, no Let's Encrypt.
- No multi-service build sprawl — the Dockerfile stays thin (official base, apt tier, user, entrypoint) with **no vendored artifacts and no baked secrets**; "relaxed no-build" means *one* minimal Dockerfile, not a build pipeline.
- No backup tooling for `/home/dev` — git-push discipline is the contract.
- Not tied to a specific host or size — portability is the point.
- No git webhook auto-deploy — manual deploy.
