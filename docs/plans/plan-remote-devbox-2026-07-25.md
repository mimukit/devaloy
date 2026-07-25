# Plan — devaloy: portable remote dev environment (SSH devbox)

Grilled: 2026-07-25

## Context
**devaloy** is a portable, self-contained Docker Compose stack: a persistent
devbox you SSH into and pick up a coding session from any device — phone or
laptop, on any network. It exists so development itself can happen remotely,
independent of the machine physically in front of you.

The design philosophy is deliberately minimal: **official images, no build
step, named volumes for persistence.** The stack brings its own tailnet
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
| Tailnet access | **Tailscale sidecar container** with its own tailnet node; the devbox uses `network_mode: service:tailscale` so its `sshd` binds only to the sidecar's tailnet IP. **No host port published → no public-IP exposure, and the "Docker `-p` bypasses `ufw`" hazard never arises.** Sidecar needs: a reusable `TS_AUTHKEY` (tagged e.g. `tag:devbox`, non-expiring), a persisted `/var/lib/tailscale` state volume (so it doesn't register a fresh node each redeploy), and `NET_ADMIN` + `/dev/net/tun` (kernel networking — userspace mode won't give the shared namespace a usable tailnet IP). |
| Base image | `linuxserver/openssh-server` — official, no custom Dockerfile/build step, with SSH + a sane user/permissions model already solved. |
| Auth | **Key-only.** `PUBLIC_KEY` env holds your SSH public key(s) (newline-separated for phone + laptop keys), `PASSWORD_ACCESS=false`. `SUDO_ACCESS=true` so ad hoc installs from inside don't need a redeploy. |
| Toolchain — apt tier | `DOCKER_MODS=linuxserver/mods:universal-package-install` + `INSTALL_PACKAGES` for apt-installable base tools: `git tmux build-essential curl vim htop`. |
| Toolchain — everything else | **mise as the universal installer.** A `custom-cont-init.d` script bootstraps mise; mise then installs node-LTS, pnpm, turbo, gh, and herdr (via its npm/ubi/core backends; fall back to a tool's own `install.sh` in the init script if it has no mise-installable release). The "array of apps to extend later" = a single mise config. mise + its installed tools live under `/config` so they persist and the init script is idempotent (skip-if-present). The SSH user's shell profile activates mise on login. |
| mosh | **Dropped.** herdr's server-side session persistence + reattach covers the reconnect need; no UDP port range to publish. |
| Persistence | Named volume at `/config` (image's home/data convention) — dotfiles, SSH **host** keys (stable across redeploys, no client MITM warnings), mise + tools, and cloned repos. Separate named volume for `/var/lib/tailscale` sidecar state. |
| Firewall (host, VPS case) | **`scripts/host-firewall-lockdown.sh`** — default deny incoming, allow outgoing, allow in on `tailscale0`, no 80/443. Anti-lockout guard: refuses to run if Tailscale is down. Hardens the *host's own* `sshd`/mgmt; defense-in-depth, not what protects the devbox (the sidecar already exposes nothing on the host). Skippable on a trusted/home host. |
| Backup | **Git-push discipline only.** No backup job, no mandated snapshots. `/config` persists across redeploys; only actual host/volume loss means re-cloning + re-`mise install`. Nothing valuable should live only on the devbox. |

## Approach

**Phase 1 — Author the portable stack** (the core deliverable)
- `compose.yml` (at the repo root — devaloy *is* the stack, not a template):
  - `tailscale` sidecar service — `tailscale/tailscale` image, `TS_AUTHKEY`/`TS_STATE_DIR=/var/lib/tailscale`/`TS_HOSTNAME=devbox`, `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun]`, named state volume.
  - `devbox` service — `linuxserver/openssh-server`, `network_mode: service:tailscale`, `INSTALL_PACKAGES` (apt base), `DOCKER_MODS`, `PUBLIC_KEY`/`PASSWORD_ACCESS=false`/`SUDO_ACCESS=true`, `/config` named volume.
- `init/` — the `custom-cont-init.d` mise bootstrap script that installs mise + the app list idempotently and wires mise activation into the login shell (mounted into `/config/custom-cont-init.d`).
- `.env.example` — documents `TS_AUTHKEY` and `PUBLIC_KEY` (both set manually; no auto-generation).

**Phase 2 — Deploy paths**
- **Plain compose (baseline):** `docker compose up -d` on any host with Docker.
- **Dokploy (optional):** Create → Compose service, set `TS_AUTHKEY` + `PUBLIC_KEY`, deploy. Verify `network_mode: service:tailscale` + Isolated Deployments coexist (the devbox joins the sidecar's namespace, not the isolated network — the sidecar handles outbound); disable isolation for this stack if they conflict.
- Confirm the sidecar appears as `devbox` in the Tailscale admin console.

**Phase 3 — (VPS host only) harden the host**
- On a cloud VPS: run `scripts/host-firewall-lockdown.sh` after Tailscale is up. Skippable on a trusted/home Docker host.

**Phase 4 — Connect and verify**
- From laptop: `ssh -p 2222 <user>@devbox` (tailnet name), confirm key auth, start a herdr session.
- From phone (Tailscale app installed): SSH client → same host → reattach the herdr session.
- Confirm no host public IP answers on the SSH port (sidecar means there's nothing to answer).
- Clone a repo into `/config`, run a `pnpm`/`turbo` build to sanity-check the toolchain, redeploy the stack, confirm repo + tools survived.

**Phase 5 — Document**
- `README.md`: what devaloy is, the one-time Tailscale auth-key + `PUBLIC_KEY` setup, `docker compose up`, and the connect-from-phone/laptop flow. State the "git-push discipline = your only backup" contract plainly.

## Open questions
- **Dokploy + `network_mode: service:tailscale` compatibility** — verify Isolated Deployments doesn't fight the shared-namespace setup; decide fallback if it does.
- **herdr install path** — confirm whether mise can install it (GitHub-release binary via ubi backend) or the init script must run herdr's own `install.sh`.
- **Exact mise app-list pins** — node-LTS is clear; decide whether to pin specific versions of pnpm/turbo/gh or track latest.
- **tmux/herdr auto-attach on login vs. manual** — minor UX call.
- **License + repo metadata** — this is now a standalone project; pick a license and a one-line description/topics if it goes public.

## Non-goals
- No browser-based IDE (code-server) — SSH only.
- No mosh.
- No host Docker socket / Docker-in-Docker — general-purpose dev doesn't warrant handing the box control of the host's containers.
- No public HTTPS domain, no Traefik, no Let's Encrypt.
- No backup tooling for `/config` — git-push discipline is the contract.
- Not tied to a specific host or size — portability is the point.
- No git webhook auto-deploy — manual deploy.
