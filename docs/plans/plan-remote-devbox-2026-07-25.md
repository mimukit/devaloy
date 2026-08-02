# Plan — devaloy: portable remote dev environment (SSH devbox)

Grilled: 2026-07-25
Revised: 2026-07-31 — **merged to a single container on Tailscale SSH.** See
[Revision 2026-07-31](#revision-2026-07-31--tailscale-ssh-single-container).
Revised: 2026-08-02 — **batteries included: zsh, agent CLIs, config as code.**
See [Revision 2026-08-02](#revision-2026-08-02--batteries-included).

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

## Revision 2026-08-02 — batteries included

Driven by the 2026-07-31 manual QA pass, where TC-9 (install Claude Code),
TC-10 (install Codex) and TC-13 (`gh auth login`) all failed. Each failure was
the same shape: a tool that has to be installed or authenticated **by hand, on
a headless box, through a browser flow that box cannot run.** A devbox you have
to hand-configure after every rebuild is not portable, whatever the README
claims.

**What changed:**

- **The image carries the tools.** `zsh`, `bat`, `btop`, `jq`, `python3` (with
  `pip`, `venv` and `python-is-python3`) join the apt tier. Claude Code and
  Codex join the **mise** tier in `bootstrap-toolchain.sh`.
- **zsh is the login shell**, set in `/etc/passwd` in the image — so it applies
  from the first boot with no `chsh` on the box.
- **Config is code.** `config/zsh/zshrc`, `config/claude/` and `config/codex/`
  ship in the repo and are copied into `/home/dev` on every boot.
- **`GITHUB_TOKEN`** authenticates `gh` and git-over-HTTPS with no interactive
  flow.
- **The login banner is gone**, along with its `.devaloy_profile` file — swept
  out of pre-existing volumes by the entrypoint, not just removed from the
  image.

**Why the agent CLIs come from mise — and the wrong turn taken first.** The
first cut of this revision installed both as system binaries in `/usr/local/bin`
at build time, via a hand-written `install-agent-clis.sh`. The reasoning was
sound as far as it went: both vendors' installers target `$HOME`, and
`/home/dev` is a volume that masks whatever the image put there, so a build-time
`$HOME` install would vanish the moment the volume mounted.

What that reasoning missed is that **mise's registry already covers both** —
`claude` (aliased `claude-code`) and `codex` — fetching the same upstream
artifacts by the same means: Claude Code's binary checksummed against its
release `manifest.json`, Codex's musl build from its GitHub release. The custom
installer was ~95 lines reimplementing an upstream-maintained registry entry.
Deleted.

**What the mise route costs and buys.** A cold volume now takes a few minutes
longer to boot, because both are large downloads that no longer sit in the
image. Bought in exchange: one package manager instead of two, no bespoke
installer to maintain, ~360MB off the image, and — the real win — both tools
live in the home volume like everything else, so a `devaloy-update` upgrade
**persists across a redeploy** instead of reverting to whatever the image was
built with. Boot ordering already puts the tailnet up before the toolchain
install, so the slower cold start is time you can watch from inside the box
rather than time you wait to reach it.

**Homebrew was evaluated and rejected.** Verified empirically on `aarch64`
Ubuntu 24.04, since two common beliefs about it are out of date: ARM64 Linux is
**Tier 1** as of Homebrew 5.0.0 (2025-11-12), and casks **do** install on Linux
as of 4.5.0 (2025-04-29) — `claude-code` and `codex` both declare
`arm64_linux`/`x86_64_linux` checksums and produce working Linux binaries. It
would genuinely work. It was rejected anyway on four counts: it is a *second*
package manager beside mise; `turbo` has no formula, so npm is still needed
regardless; the prefix must be `/home/linuxbrew/.linuxbrew` or all bottles are
lost; and — decisive — Homebrew's own documentation disclaims the version
pinning this design depends on (*"Homebrew's versions should not be used to
'pin' formulae to your personal requirements"*; `brew pin` freezes what is
installed and cannot select a version). Measured cost had we adopted it: a
**1.3GB prefix** installed in 197s, pulling 32 formulae of transitive
dependencies. Also worth recording: Ubuntu 24.04's glibc 2.39 is *exactly* the
Tier 1 minimum, so a base-image downgrade to 22.04 would silently drop us to
Tier 2, where no new bottles are built.

**Config sync policy: the repo wins.** Managed files are overwritten on every
boot, so editing one in the repo and redeploying actually changes the box — and
editing one on the box does not survive. The copy **merges** rather than
replaces, so credentials, session history, and files the repo does not ship are
untouched. zsh gets an escape hatch (`~/.zshrc.local`, sourced last, never
written); Claude Code and Codex have no include mechanism, so they get none.
The alternative — seed-once — was rejected because it makes a repo edit silently
do nothing to an existing box, which is the worse failure mode.

**`GITHUB_TOKEN` moves a credential into the home volume.** The entrypoint
writes it to `~/.devaloy_secrets` (mode 600) rather than trusting the container
environment to reach a shell, because `tailscaled` spawns login shells itself
and what it forwards from PID 1's environment is its business, not a contract.
The file is rewritten from scratch on every boot, so clearing the variable and
redeploying genuinely revokes it. Trade accepted: a live credential now sits in
the volume, in exchange for `git push` working from a phone with no browser.

**Rejected: `lazydocker`.** It needs `/var/run/docker.sock`, and mounting the
host's Docker socket into the container that runs arbitrary npm packages and AI
agents is root-equivalent access to the host. "No host Docker socket access"
stays a non-goal.

## Design decisions (settled)

Rows marked **[R2]** were changed by the 2026-07-31 revision; **[R3]** by the
2026-08-02 revision.

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
| Toolchain — apt tier **[R3]** | Installed in the Dockerfile: `sudo git tmux build-essential curl ca-certificates vim htop btop bat jq zsh python3 python3-pip python3-venv python-is-python3`, plus `iproute2`/`iptables` (tailscaled) and `openssh-client` (outbound git-over-ssh). `openssh-server` is **gone**. `bat` is symlinked from Ubuntu's `batcat` into `/usr/bin`, not `/usr/local/bin` — `link-shims` owns the latter and overwrites symlinks it finds there. |
| Agent CLIs **[R3]** | **Claude Code and Codex via mise**, in `bootstrap-toolchain.sh` alongside the rest. mise's registry fetches the same upstream artifacts the vendors' own installers do, checksummed, so there is nothing bespoke to maintain. They live in the home volume, so `devaloy-update` upgrades persist across redeploys. Both track `latest` like pnpm/gh/turbo; pin in that file. Cost: a cold volume boots a few minutes slower. |
| Package manager **[R3]** | **mise only.** Homebrew was evaluated on `aarch64` and genuinely works — ARM64 Linux is Tier 1, and the `claude-code`/`codex` casks install on Linux — but was rejected: a second package manager, no `turbo` formula, a mandatory prefix, a 1.3GB footprint, and documentation that explicitly disclaims the version pinning this design relies on. |
| Login shell **[R3]** | **zsh**, set in `/etc/passwd` in the image so it applies from first boot with no `chsh`. `~/.zshenv` sources `.devaloy_env` — which covers non-interactive sessions *natively*, unlike bash's socket-stdin quirk, though `link-shims` stays as belt-and-braces. `.devaloy_env`'s PATH prepend is now idempotent, since three separate startup files can reach it. |
| Config as code **[R3]** | **`config/` in the repo → `/home/dev` on every boot.** `config/zsh/zshrc`, `config/claude/`, `config/codex/`. The repo wins; the copy merges rather than replaces, so credentials and unshipped files survive. Escape hatch: `~/.zshrc.local` for zsh only. |
| GitHub auth **[R3]** | **`GITHUB_TOKEN` in `.env`.** The entrypoint writes it to `~/.devaloy_secrets` (0600) and runs `gh auth setup-git`, so `gh` and `git push` over HTTPS work with no browser — the thing TC-13 could not do from a phone. Puts a live credential in the home volume; rewritten every boot, so clearing it revokes it. |
| Toolchain — everything else | **mise as the universal installer**, via `bootstrap-toolchain.sh` (single source of truth for the tool list and pins, shared by the entrypoint and `devaloy-update`). herdr is officially mise-installable (`mise use -g herdr` — confirmed, 0.7.5). mise + tools live in the persistent home so they survive redeploys. |
| Non-interactive PATH **[R2]** | **`link-shims` mirrors mise shims into `/usr/local/bin`.** Bash only auto-sources `.bashrc` in a non-interactive shell when stdin is a *socket* — an OpenSSH implementation detail that no longer applies without `sshd`. Without the mirror, `ssh devbox '<cmd>'`, `scp`, `rsync` and git-over-ssh would silently lose the toolchain. `.devaloy_env` (sourced from the **top** of `.bashrc`, above Ubuntu's interactivity guard) still covers interactive shells. |
| Version pins (mise) | **Pin the session-critical + track the stable.** Pin **node** to an LTS major (not mise's floating `lts` alias, which rolls across majors). `gh`/`pnpm`/`turbo` track latest. herdr tracks latest by default but is gated behind the toolset-revision marker so a redeploy can't swap it under a live session; `MISE_HERDR_VERSION` pins it. |
| Toolset marker **[R4]** | **`TOOLSET_REVISION` in `bootstrap-toolchain.sh`, recorded in the home volume.** The gate lives in the same file as the tool list, and the boot path re-runs whenever the two disagree. The original marker recorded only *that* the bootstrap had run, which meant a volume provisioned before `claude`/`codex` were added skipped them forever — the defect that made QA TC-4, TC-5 and TC-9 fail. Bumping re-resolves the `@latest` tools, so bump only when the tool list actually changes. |
| Toolchain updates | **`devaloy-update`** — runs `bootstrap-toolchain.sh --force`, refreshes the `/usr/local/bin` mirror. Refuses to run as root. The deliberate upgrade path, so boot stays predictable. |
| Resilience / ops **[R2]** | **`restart: unless-stopped`.** `depends_on` is gone with the sidecar. |
| OOM safety | **Host swap + session protection.** No hard `mem_limit` (that would hardcode a host-size assumption). Compose sets `oom_score_adj: -500` so the kernel avoids killing `tailscaled` — losing it severs the only route in. Each shell raises itself back to `0` via `.devaloy_env`, so a runaway build is the preferred victim. Raising is unprivileged; only lowering needs `CAP_SYS_RESOURCE`, which Docker applies itself. |
| Login UX **[R3]** | **Manual herdr, no hint.** Still not auto-attaching — that breaks `scp`/`sftp`/`rsync`/git-over-ssh. The `run: herdr` banner is **gone**: it printed on every single session to tell you something you learn once. The entrypoint deletes `.devaloy_profile` and strips its `.bashrc` line, so volumes created before this revision lose it too. |
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
- `entrypoint.sh` — write `.devaloy_env`/`.devaloy_profile` and wire them into `.bashrc`; start `tailscaled`; `tailscale up --ssh --timeout=90s`; mise bootstrap (gated on `TOOLSET_REVISION` inside `bootstrap-toolchain.sh`, non-fatal); `link-shims`; `wait`.
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
- No multi-service build sprawl — the Dockerfile stays thin (official base, apt tier, user, entrypoint, managed config) with **no vendored artifacts and no baked secrets**. **[R3]**
- No second package manager — mise installs everything apt does not. See the Package manager row for why Homebrew was evaluated and rejected. **[R3]**
- No `lazydocker` and no `/var/run/docker.sock` mount — see the socket non-goal above; the tool is unusable without it, so it is simply left out. **[R3]**
- No backup tooling for `/home/dev` — git-push discipline is the contract.
- Not tied to a specific host or size — portability is the point.
- No git webhook auto-deploy — manual deploy.
- **No SSH key management, no password auth, and no fallback `sshd`** — Tailscale SSH is the only door.
