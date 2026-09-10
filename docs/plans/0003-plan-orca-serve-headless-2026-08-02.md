# Plan — `orca serve` headless on devaloy

Drafted: 2026-08-02
Grilled: 2026-08-02
Status: ready for implementation

## Context

devaloy today is reachable exactly one way: Tailscale SSH into a shell, and
from there `herdr` + the agent CLIs. That is enough for a laptop and enough for
a phone with an SSH client, but it is not enough for the **Orca desktop or
mobile app**, which speak to a runtime rather than a terminal.

Orca offers four ways to run, and only one of them accepts a mobile client
directly:

| Mode | Mobile? | Who owns the session state | Needs the desktop? |
|------|---------|----------------------------|--------------------|
| Local desktop | No | Your laptop | It *is* the laptop |
| SSH targets | No | Your desktop, driving a remote shell | Yes — it drives the remote |
| **Remote Orca Server (`orca serve`)** | **Yes** | **The server** — "clients are the UI" | **No** — the phone alone is a complete client |
| Cloud VM per-workspace | Only if the recipe itself starts `orca serve` | A disposable VM per worktree | Yes — it provisions and reaps them |

The last two are easy to conflate, so: they differ on **lifetime and
ownership**, not on whether your laptop can sleep. A Remote Orca Server is *one
persistent runtime* that owns projects, worktrees, terminals and agent
processes. Cloud VM is a *provisioning strategy* — many disposable sandboxes
built from an `orca.yaml` recipe, where "create spins it up; suspend/resume/
destroy tear it down", orchestrated by your desktop, on your own cloud account
and billing. Its only path to mobile is a recipe that runs `orca serve` inside
each VM — so it is not an alternative to this plan, it is a wrapper that would
need this plan's work anyway, on ephemeral infra, behind a Settings →
Experimental flag.

devaloy is already the always-on box, so the goal picks the mode for us. Success looks like: the Orca mobile app
pairs to devaloy over the tailnet, agents keep running after the laptop sleeps,
and the pairing survives a `docker compose down && up` — with **no `ports:` key
added** and no public exposure, preserving the property that the tailnet is the
only *remote* way in.

The prerequisite research (options compared, container behaviour verified by
running the thing in `ubuntu:24.04`) is in this repo's conversation history; its
load-bearing findings are recorded as settled decisions below rather than
re-derived here.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Which Orca run mode | **Remote Orca Server (`orca serve`)**. The only mode the mobile app can connect to, and the only one that survives the laptop sleeping. |
| Install artifact | **The `orca-ide` `.deb`**, not the AppImage the official headless guide recommends. Verified: on minimal noble the AppImage leaves **20 shared libs missing**; the deb + apt resolves all but five. The deb also needs no FUSE and no `--appimage-extract` dance. |
| The deb's missing deps | Its `Depends` is **incomplete** — it lists only `python3`, `python3-gi`, `gir1.2-atspi-2.0`, `at-spi2-core`, `xdotool`, `xclip`, `xvfb` and omits Electron's whole Chromium runtime. **Corrected during implementation:** on a genuinely minimal noble base the shortfall is **eight** libraries, not the five originally recorded — `libatk-1.0`, `libatk-bridge-2.0`, `libcups`, `libgtk-3`, `libpango-1.0`, `libXcomposite`, `libXdamage`, `libXfixes`, on top of `libnss3`/`libasound`. Adding **`libnss3`, `libasound2t64`, `libgtk-3-0t64`, `libatk-bridge2.0-0t64`, `libcups2t64`** closes all of it (gtk3 pulls pango/atk/libX* transitively). Verified `ldd`-clean. (Upstream packaging bug; file it.) |
| Where it installs | **The Dockerfile**, not `bootstrap-toolchain.sh`. It is a system package with apt-resolved deps and no mise registry entry — the same reason `tailscale` lives in the image. Trade: upgrading needs an image rebuild, not `devaloy-update`. |
| How the deb is fetched | In the existing **`fetch` stage**, then installed via `--mount=type=bind,from=fetch`. Matches the file's stated philosophy (network fetches isolated from the churning package list) and keeps the 160 MB artifact out of any image layer. |
| Version pinning | Pinned `ARG ORCA_VERSION` (currently `1.4.164`), arch-matched with `dpkg --print-architecture`. Orca ships both `amd64` and `arm64` debs, so this stays ARM-VPS-compatible. |
| Display | **`xvfb-run -a`**. The official managed-Xvfb alternative is a second systemd unit — irrelevant with no init system here. |
| Chromium sandbox | **Kept.** Run as `dev`, never `--no-sandbox`. The sandbox needs user namespaces, which Docker's default seccomp blocks — devaloy **already sets `seccomp=unconfined`** for Codex's bubblewrap, so this works with no compose change. Verified: with default seccomp it dies on `zygote_host_impl_linux.cc`; with the flag off it boots and binds. |
| Launch point | `entrypoint.sh`, **after `tailscale up`** (needs the IP) and **after `link-shims`** (Orca shells out to `codex`/`claude`; a run without them on PATH logs `spawn codex ENOENT`). |
| Advertised address | `--pairing-address "$(tailscale ip -4 \| head -1)"`. If `tailscale up` failed there is no address worth advertising, so **skip the launch and warn** rather than serve something unreachable. |
| Port / exposure | `--port 6768`, and **no `ports:` key**. `tailscaled` runs in this container's netns, so the tailnet IP already reaches it — the same reason Tailscale SSH works here. See "Bind scope" below for what that does and does not claim. |
| State | Untouched. Orca keeps state in `$HOME/.config/`, already on the `home` volume, so paired-device tokens survive redeploys for free. |

### Settled by grilling

| Decision | Resolution |
|----------|-----------|
| **Bind scope** | Orca binds `0.0.0.0`, so 6768 is also reachable on the container's docker bridge IP. **Accepted, not firewalled.** Anyone on the Docker host already holds the daemon socket and can `docker exec` in as root — 6768 grants them nothing new. `scripts/host-firewall-lockdown.sh` is deliberately left alone: its scope is the host's own sshd surface, it is optional, and `ufw` does not manage `DOCKER-USER` cleanly. Action is a **comment rewrite** in `docker-compose.yml`, stating precisely that nothing is published, the tailnet is the only *remote* way in, and 6768 is reachable from the Docker host itself — plus a warning against attaching other containers to this network. |
| **Feature toggle** | A single **build `ARG WITH_ORCA`, default `false`**. An env var cannot do this job: it is read at runtime, so the payload would be baked in regardless. **Measured during implementation:** the real cost is 683 MB → 1.6 GB on arm64, not the "~540 MB / roughly triples" first estimated. Wired through compose as `build.args`, driven from `.env`. **No runtime `ORCA_SERVE` toggle** — one name, one concept, no contradictory states. Trade accepted: disabling a misbehaving runtime costs a rebuild, not a restart. |
| **Where the gated block lives** | **One contiguous `RUN` block at the bottom of the Dockerfile**, holding *both* the extra apt packages (`xvfb`, `xdotool`, `xclip`, `python3-gi`, `gir1.2-atspi-2.0`, `at-spi2-core`, `libnss3`, `libasound2t64`) and the deb install. Not folded into the shared apt block. Two reasons: replacing Orca with a different tool later is deleting one block, and flipping the arg does not invalidate the main apt layer. Costs one extra `apt-get update` round trip, cheap behind the existing cache mounts. |
| **Loop escape** | **Unbounded restart loop, no sentinel file and no retry cap.** The backoff sleep already stops a crash-loop spinning hot. Escape hatch is `docker compose stop` or a rebuild with `WITH_ORCA=false`; the README says so plainly rather than implying a lighter touch exists. |
| **Autoupdater** | **Accepted as a documented unknown.** Docs say headless never self-updates; the running server logged `[autoUpdater] Checking for update` anyway, and the behaviour when an update *exists* stays unobserved. `/opt` is root-owned and Orca runs as `dev`, so it cannot self-apply. README records the residual risk: a check may download a ~160 MB artifact onto the `home` volume. |
| **dbus** | **Not added.** Ship without it and treat `Failed to connect to the bus` as cosmetic. The coupling that matters: Electron's `safeStorage` reaches for libsecret over dbus and silently falls back to weaker encryption without it — and that is the machinery holding paired-device tokens. **Phase 4's `down && up` pairing test is the arbiter.** If pairings survive, dbus was never load-bearing. If they do not, `dbus-x11` + `dbus-run-session` is the first fix, added with a known reason instead of on faith. |
| **OOM priority** | **`-250`, set explicitly.** Correcting the draft's premise: `oom_score_adj` is *inherited*, the container starts at `-500`, and `as_dev` runs `su -l -s /bin/sh`, which reads neither `.zshenv` nor `.bashrc` — so an un-touched Orca would inherit `-500` and be as protected as `tailscaled`, while builds and agents sit at `0` and die first. That is backwards. `-250` puts the runtime between the two: it outranks a runaway build because losing it costs mobile access, and never outranks `tailscaled`, the only recovery path. Raising above an inherited `-500` is unprivileged, so no compose change and no `CAP_SYS_RESOURCE`. |
| **Two servers on one tailnet** | **Doc line only.** `WITH_ORCA=false` by default is already the practical guard — a second devaloy needs a deliberate opt-in in its own `.env` to get here at all. A runtime guard would mean probing the tailnet for another advertiser with no documented API, and a false positive (silently no server) is worse than the mistake it prevents. |

## Approach

Four phases. Phase 1 is the only one with real unknowns; 2–4 are mechanical
once it lands.

**Reused as-is, no new machinery:** the `fetch` build stage and its BuildKit
cache mounts, the `as_dev` helper, the `log` convention, the non-fatal-warning
pattern from the toolchain bootstrap, `link-shims` for agent-CLI PATH, the
`home` volume for state, and `seccomp=unconfined` + `oom_score_adj` already in
`docker-compose.yml`.

### Phase 1 — Image: Orca and its real dependency set

1. Add to the `fetch` stage: download the arch-matched deb to `/out/orca.deb`,
   driven by `ARG ORCA_VERSION=1.4.164` and `dpkg --print-architecture`.
   Note: the fetch runs unconditionally even when `WITH_ORCA=false`, because
   the bind mount in step 3 makes the stage a build dependency regardless of
   the shell conditional inside it. This costs a one-time 160 MB download that
   never enters the final image and is layer-cached thereafter. If that build
   cost ever bites, the escape is the BuildKit stage-alias idiom
   (`FROM orca-fetch AS orca-src-true` / `FROM scratch AS orca-src-false` /
   `FROM orca-src-${WITH_ORCA} AS orca-src`) — deliberately *not* done up front,
   because it trades real legibility for a cost paid once.
2. Add `ARG WITH_ORCA=false` and a **single gated `RUN` block at the bottom of
   the Dockerfile**, containing everything Orca needs and nothing else:
   - the apt packages `xvfb`, `xdotool`, `xclip`, `python3-gi`,
     `gir1.2-atspi-2.0`, `at-spi2-core`, `libnss3`, `libasound2t64`;
   - the deb install itself.
   Comment *why* `libnss3`/`libasound2t64` are there — they look redundant next
   to a deb that should have declared them, and a future reader will delete
   them otherwise. Comment the block's boundaries too: this is the unit you
   delete when Orca is replaced.
3. Install the deb inside that block with
   `RUN --mount=type=bind,from=fetch,source=/out/orca.deb,target=/tmp/orca.deb`
   plus the apt cache mounts already used elsewhere.
4. Verify `/opt/Orca/chrome-sandbox` is mode `4755` after install. The deb's
   `postinst` is expected to set it; if it does not, set it explicitly — the
   sandbox decision above depends on it.
5. Verification gate, with `WITH_ORCA=true`: `ldd /opt/Orca/orca-ide | grep
   "not found"` returns **nothing**. With `WITH_ORCA=false`: `/opt/Orca` does
   not exist and the image size is unchanged from `main`.

### Phase 2 — Entrypoint: launch and supervise

6. Add the Orca block to `entrypoint.sh`, placed after the `link-shims` call
   and before the final `wait`.
7. Guard on two things: `/usr/bin/orca-ide` is executable, and a tailnet IPv4
   exists. **Corrected during implementation:** `/opt/Orca/orca-ide` is the raw
   Electron binary, not the CLI. The deb's `postinst` symlinks
   `/usr/bin/orca-ide` to a shim that re-execs Electron with
   `ELECTRON_RUN_AS_NODE=1` against the bundled CLI entry point — invoking the
   raw binary with `serve` would try to open a GUI instead. Guard on and launch
   the shim. (`postinst` also does the `chmod 4755` on `chrome-sandbox`, so
   Phase 1's fallback is unnecessary; the build asserts it rather than sets it.) **The missing-binary case must be silent** — it is the default build,
   not a fault, and a stock `WITH_ORCA=false` image must never warn about a
   binary it was never asked to install. The missing-IP case warns and skips.
8. Launch as `dev` in a backgrounded, unbounded restart loop with
   `LIBGL_ALWAYS_SOFTWARE=1` and a backoff sleep, so a crash-loop cannot spin
   hot.
9. Set `oom_score_adj` to `-250` in the launch wrapper, before exec — not
   inherited. Comment why the explicit value exists, or a future reader will
   assume the inherited `-500` was intended.
10. Log the pairing hint explicitly — the URL prints to the container log, which
    is a non-obvious place to look. Mirror the existing
    `"Connect with: ssh dev@..."` line.
11. Verification gate: `docker compose logs devaloy` shows the ready block and
    a pairing URL; `ss -ltn` inside the container shows `0.0.0.0:6768`; and
    `cat /proc/$(pgrep -f orca-ide | head -1)/oom_score_adj` reads `-250`.

### Phase 3 — Compose and documentation

12. `docker-compose.yml`: convert `build: .` to the long form with
    `args: {WITH_ORCA: "${WITH_ORCA:-false}"}`. Rewrite the `ports:` comment per
    the Bind scope decision — nothing published, tailnet is the only *remote*
    way in, 6768 reachable from the Docker host itself, do not attach other
    containers to this network. No `environment:` entry is added; there is no
    runtime toggle.
13. `README.md`: a "Connecting" subsection for pairing desktop and mobile, plus
    `WITH_ORCA` documented as a **build** arg. It must say, explicitly:
    - `docker compose up -d` alone will **not** pick up a changed build arg —
      `--build` is required. This is the single most likely footgun.
    - Upgrading Orca means bumping `ORCA_VERSION` and rebuilding;
      `devaloy-update` does **not** cover it, a genuine break from how every
      other tool on the box upgrades.
    - There is no runtime kill switch. A wedged Orca means `docker compose stop`
      or a rebuild with `WITH_ORCA=false`.
    - The autoupdater chatters and may pull a ~160 MB artifact onto the `home`
      volume; it cannot self-apply because `/opt` is root-owned.
    - Run `orca serve` on one devaloy at a time.
14. `docs/wiki/`: a page for the pairing walkthrough, matching the existing
    `deploy-with-dokploy.md` shape.
15. `config/claude/CLAUDE.md` and `config/codex/AGENTS.md`: both currently tell
    the on-box agents that `orca-cli`/`orcakit` are inert "no Orca here". With a
    runtime present that is now **conditionally** wrong — qualify it against
    `WITH_ORCA` rather than flipping the claim outright, since the default build
    still has no Orca.

### Phase 4 — Prove it end to end

16. Cold boot on an empty volume with `WITH_ORCA=true`: image builds, box joins
    the tailnet, Orca binds, pairing URL appears.
17. Also boot once with the default `WITH_ORCA=false` and confirm the log is
    clean — no warnings, no missing-binary noise.
18. Pair the desktop app; then re-run with `--mobile-pairing` by hand for the
    QR and pair the phone.
19. `docker compose down && up` — confirm paired devices reconnect without
    re-pairing. This proves the `$HOME/.config` state assumption **and** settles
    the dbus question: if pairings are lost, `safeStorage`/libsecret is the
    first suspect and `dbus-x11` + `dbus-run-session` is the fix.
20. Confirm an agent actually runs from the Orca client, not just that the
    server binds — this is what catches a PATH regression around `link-shims`.
21. Write it up in `docs/qa/` following the existing QA docs' format.

### Alternatives rejected

- **AppImage per the official guide** — 20 missing libs on this base image,
  plus FUSE or an extraction step. The deb is strictly less work here.
- **SSH targets mode** — zero new packages, but no mobile and the desktop must
  stay awake. It fails the actual goal.
- **Installing via `bootstrap-toolchain.sh`** — no mise registry entry, and apt
  dependency resolution does not belong in the home volume.
- **A runtime `ORCA_SERVE` toggle alongside `WITH_ORCA`** — a second knob that
  can contradict the first, for a 5-second-vs-rebuild saving in a failure mode
  that has not happened yet. One name, one concept.
- **A firewall rule for 6768** — `scripts/host-firewall-lockdown.sh` guards the
  host's own management surface, is optional, and does not manage `DOCKER-USER`.
  It would not protect the hosts most likely to need it, against an actor who
  already has the Docker socket.
- **Cloud VM per-workspace environments** — disposable sandboxes are a real
  want, but they reach mobile only by running `orca serve` inside each VM. It
  would sit *on top of* this plan, not instead of it, and it adds a cloud bill
  and an experimental flag to get there. Revisit once the persistent runtime is
  proven.

## Non-goals

- **Replacing Tailscale SSH.** It stays the primary and the recovery path;
  `orca serve` is additive, and `wait` stays on `tailscaled` for exactly that
  reason.
- **Public internet exposure.** No `ports:`, no reverse proxy, no TLS
  termination. Tailnet only.
- **Cloud-VM / per-workspace `orca.yaml` recipes.** A different mode for a
  different problem.
- **Making `verifykit` work on the box.** Orca bringing a Chromium along is
  incidental and not to be relied on as a browser for other tooling.
- **Auto-upgrading Orca.** Pinned and rebuilt deliberately, unlike the mise
  toolchain.
- **Orca on by default.** `WITH_ORCA=false` is the default build; this is an
  opt-in capability, not part of devaloy's baseline story.
