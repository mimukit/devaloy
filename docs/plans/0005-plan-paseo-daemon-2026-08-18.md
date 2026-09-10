# Plan — the Paseo daemon on devaloy

Drafted: 2026-08-18
Grilled: 2026-08-19
Status: ready for implementation

## Context

devaloy is reachable two ways today. Tailscale SSH is the baseline, and a build
with `WITH_ORCA=true` adds the `orca serve` runtime so the Orca desktop and
mobile apps can pair with the box.

[Paseo](https://paseo.sh) is a second client family for the same job: a
self-hosted daemon that owns agent processes, worktrees and terminals, driven
from iOS, Android, desktop, a browser, or the `paseo` CLI. It speaks to Claude
Code, Codex, Copilot, OpenCode and roughly thirty other agents, and it ships an
MCP server so an agent already running on the box can spawn and coordinate other
agents.

Three properties make it a much cheaper guest than Orca:

| | Orca | Paseo |
|---|---|---|
| Artifact | 154 MB arch-matched `.deb`, Electron and Chromium underneath | pure npm package, no native binary, no arch matching |
| Image cost | 683 MB to 1.6 GB, so the toggle had to be a build argument | none, it installs into the home volume like `claude` and `codex` |
| Bind address | `0.0.0.0` with no flag to change it, so port 6768 leaks onto the Docker bridge | defaults to `127.0.0.1`, takes `--listen <host>:<port>` |

That last row is why this is not a copy of the Orca block. Orca forced devaloy to
accept a port reachable from the Docker host. Paseo defaults to loopback, and the
tailnet bind is a deliberate widening rather than a failed narrowing.

Success looks like: `WITH_PASEO=true` in `.env`, `docker compose up -d` with no
`--build`, and the Paseo mobile app connects to `<tailnet-ip>:6767` and runs a
Claude Code agent that survives the laptop sleeping. No `ports:` key is added,
nothing new is reachable from the Docker host, and turning the key back off stops
the daemon on the next boot.

## Verified during grilling

Read from the Paseo source rather than the docs, because each one changed a
decision below.

| Claim | Evidence |
|---|---|
| `paseo daemon start --foreground` cannot prompt | `daemon/start.ts` calls `startLocalDaemonForeground`, which is a `spawnSync` of the supervisor entry with `stdio: "inherit"`. Nothing interactive is on that path. The relay prompt lives in the bare `paseo` onboarding and in `daemon pair`. |
| MCP binds no port of its own | `server/bootstrap.ts` builds the agent MCP base URL from the same `ListenTarget` as the HTTP server. One socket. |
| The default listen is loopback | `parseListenString` maps a bare port to `127.0.0.1`, and the CLI sets `PASEO_LISTEN=127.0.0.1:<port>` when only `--port` is given. |
| Paseo already supervises itself | `scripts/supervisor-entrypoint.ts` runs the worker with `restartOnCrash: true` and holds a PID lock under `PASEO_HOME`. |
| Flags and env are the same thing | `buildChildEnv` converts `--listen`, `--hostnames` and `--web-ui` into `PASEO_LISTEN`, `PASEO_HOSTNAMES` and `PASEO_WEB_UI_ENABLED` for the child process. |
| Workspace services bind no extra ports | `service-proxy.ts` routes them by virtual host on the daemon port, at names like `<script>-<branch>-<project>.localhost:6767`. |
| Re-running the toolchain bootstrap is cheap | The boot path runs `mise install`, never `mise upgrade`, which is `--force` only. `bootstrap-toolchain.sh:90` records that the `mise use -g …@latest` lines do not move an already-installed tool. |

## Design decisions (settled)

### Install and toggle

| Decision | Resolution |
|----------|-----------|
| Where it installs | **`bootstrap-toolchain.sh`**, via mise's npm backend, next to `npm:turbo` and `npm:skills`. Paseo is a JavaScript package with JavaScript dependencies. There is no system package, no apt resolution and no architecture to match, so none of the reasons that pushed Orca into the Dockerfile apply. It lands in the home volume and `devaloy-update` upgrades it, like every other tool on the box. |
| The key | **`WITH_PASEO`, a runtime environment variable**, default `false`. This is the deliberate opposite of `WITH_ORCA`. Orca had to be a build argument because the payload is baked into the image; Paseo's payload lives in the home volume, so a plain `docker compose up -d` is enough to flip it. The name keeps the `WITH_` family on purpose, and the README, `.env.example` and reference table each say plainly that this one is runtime. |
| Version pin | **`MISE_PASEO_VERSION`, default `latest`**, forwarded from compose exactly as `MISE_HERDR_VERSION` already is. Paseo ships often and the revision marker already stops a redeploy swapping it under a live session. |
| The install gate | The `TOOLSET_REVISION` marker **records the flag as well as the revision**, so the value written to and compared against `.devaloy-bootstrapped` is `5` or `5+paseo`. Without this, a volume already at the current revision skips the bootstrap entirely and a later `WITH_PASEO=true` installs nothing. That is the exact trap the script's header comment describes for `claude` and `codex`. Re-running on a flip is close to free: the boot path never upgrades, so every already-installed tool stays where it is. |
| Turning it off | **`WITH_PASEO=false` stops the daemon on the next boot. It removes neither the CLI nor `~/.paseo`.** A `paseo` binary with no daemon is inert, pulling a tool out from under a live session is worse than leaving a dormant command on `PATH`, and deleting the state would destroy paired devices over a key someone may have flipped by accident. The README states exactly what the key does and does not remove. |

### Network and trust

| Decision | Resolution |
|----------|-----------|
| Listen address | **`--listen <tailnet-ipv4>:6767`**. The daemon binds the tailnet interface only. Nothing appears on the Docker bridge, which is a strictly better position than the one `orca serve` forced. No `ports:` key, same as today. |
| No tailnet IPv4 | **Warn and skip the launch**, mirroring the Orca block. A daemon bound to an address nothing can route to fails at connect time instead of here, where the log can explain why. |
| The IPv4 changing later | **Accepted and documented.** The daemon captures the address once at boot, so a `tailscaled` re-registration on a different IPv4 leaves a socket on an address the box no longer holds. The node identity lives in the `tailscale-state` volume and the address is stable across its life, and the fix is restarting the container. A watchdog comparing the bound address to `tailscale ip -4` is real machinery for a rare event. |
| Relay | **`--no-relay` on every launch.** Paseo's relay is an outbound end-to-end encrypted tunnel to `app.paseo.sh` that lets a phone reach the daemon with no VPN. It is off for new installations upstream, and passing the flag explicitly makes it impossible for a stray `config.json` edit to turn it on. Leaving it reachable would break the property that the tailnet is the only remote way in, which is the whole shape of this box. |
| Password | **`PASEO_PASSWORD` is a real devaloy key, optional, with the `write_secret` lifecycle.** It goes into `~/.devaloy_secrets` at 0600, is rebuilt from scratch each boot, and clearing it in `.env` plus a redeploy revokes it. The launch line already sources that file, so the daemon receives it with no extra wiring, and the on-box CLI picks it up for `paseo ls`. Leaving it empty is supported: the tailnet is then the only gate, the same trust model Tailscale SSH already runs on. Note the scope: Paseo's password is daemon-wide, so setting it also makes the phone's direct connection ask for it. It is not a web-UI-only credential. |
| Web UI | **Off by default, behind a second key `WITH_PASEO_WEB_UI`.** When on, `--web-ui` makes `http://<tailnet-ip>:6767/` a full client in any browser with no app install. |
| Web UI without a password | **Warn loudly, serve anyway.** The requirement is documentary, not enforced in code. Withholding the feature would cost the box a working surface over a configuration choice, and gating only the UI while the WebSocket API stays open on the same address protects nothing real. The warning earns its place by firing exactly when the risk appears, which a standalone optional key would never do. |
| Hostnames | Only relevant when the web UI is on: pass **`--hostnames "${TS_HOSTNAME},.ts.net"`**. Paseo allows bare IPs and `localhost` by default and rejects DNS names, so a MagicDNS visit would otherwise return `403 Host not allowed`. |
| Workspace service previews | **Out of scope, documented.** Paseo proxies a workspace's dev servers by virtual host on 6767, at `<script>-<branch>-<project>.localhost`. That name does not resolve from a phone on the tailnet, and making it resolve needs wildcard DNS pointing at the tailnet IP, which MagicDNS does not provide. Agents, terminals, diffs and git all work. The wiki page names the one thing that does not, and names DNS as the reason rather than blaming Paseo. |
| Port | **6767**, Paseo's default. No clash with Orca's 6768, so a box built `WITH_ORCA=true` can run both. |

### Process and state

| Decision | Resolution |
|----------|-----------|
| Supervision | **`paseo daemon start --foreground` inside the same backgrounded restart loop the Orca block uses.** Detached mode would move the daemon log out of `docker compose logs`, which is the recovery surface when the tailnet is down. The outer loop is a second layer on purpose: Paseo's supervisor restarts the worker, and nothing but the outer loop restarts the supervisor. It costs nothing while the inner layer is working. |
| Stale PID lock | The supervisor holds a PID lock under `PASEO_HOME`. A `SIGKILL`ed daemon may leave one behind, and a relaunch that refuses to start would wedge the restart loop into a warning every ten seconds. **Phase 5 tests this directly** rather than assuming the lock self-reclaims. |
| Configuration | **CLI flags only. No `config.json` is written.** Paseo treats launch flags as authoritative over the file and reports any file setting they override. Driving it entirely from flags means the daemon's behaviour is readable in `entrypoint.sh` instead of split across a file in the home volume that nothing rebuilds. |
| Agent credentials | The launch **sources `~/.devaloy_secrets` inside the `as_dev` command string**. Agents Paseo spawns inherit the daemon's environment, and `as_dev` runs `su -l -s /bin/sh`, which reads neither `.zshenv` nor `.bashrc` and so never sees `CLAUDE_CODE_OAUTH_TOKEN`. This is the same failure the `gh auth login --with-token` block already exists to work around, and without it a Claude Code agent launched from the phone falls back to a `~/.claude/.credentials.json` that a token-provisioned box does not have. Sourcing the file beats inlining a hand-maintained variable list, which goes stale silently, and beats `zsh -lc`, which re-introduces the login shell `as_dev` deliberately avoids while the entrypoint is still rewriting those files. |
| MCP | **Left at its defaults.** The MCP server is on and Paseo injects its agent-orchestration tools into every agent it launches. Orchestrating agents from the phone is much of why Paseo is worth running here. The wiki page names the injection, so a surprising tool list inside a session has a documented cause. |
| Log level | **Default `info` on the console.** Paseo also writes `$PASEO_HOME/daemon.log` at trace with rotation, so nothing is lost if this later needs quieting. Phase 5 reads the container log after an idle hour and settles it with evidence rather than tuning a problem nobody has seen. |
| Launch point | `entrypoint.sh`, **after `link-shims`** and after the Orca block. Paseo shells out to `claude` and `codex`, and `su -l -s /bin/sh` does not get mise's shims. `link-shims` mirroring them into `/usr/local/bin` is what makes them resolvable, exactly as it is for Orca. |
| OOM priority | **`-250`, set explicitly in the launch subshell.** Same reasoning as Orca: the container starts at `-500` to protect `tailscaled`, `oom_score_adj` is inherited, so an untouched daemon would outrank the only process that keeps you connected. `-250` puts it above a runaway build and below `tailscaled`. |
| Missing binary | **Warn, do not stay silent.** This is the inverse of the Orca block. A missing `orca-ide` is the default build and therefore not a fault; a missing `paseo` when `WITH_PASEO=true` means the bootstrap failed, and the log should say so. |
| State | **Nothing to do.** `PASEO_HOME` defaults to `~/.paseo`, which is already inside the `home` volume, so paired devices and daemon state survive a redeploy for free. |

## Approach

Five phases. Phase 1 carries the only structural change to an existing file;
the rest follow the shape the Orca work already laid down.

**Reused as is, no new machinery:** the `as_dev` helper and the `log`
convention, the `write_secret` helper and its 0600 secrets file, the
backgrounded restart loop and explicit `oom_score_adj` from the Orca block,
`link-shims` for agent-CLI `PATH`, mise's npm backend as already used for
`turbo` and `skills`, the `MISE_HERDR_VERSION` passthrough pattern for the
version pin, the `home` volume for state, and the `docs/wiki/.wikimap.yaml` page
registry.

### Phase 1 — Install the CLI behind the key

1. `bootstrap-toolchain.sh`: read `WITH_PASEO` (default `false`) and
   `MISE_PASEO_VERSION` (default `latest`) near the existing pin block.
2. Change the marker to carry the flag. `TOOLSET_REVISION=5`, and the value
   written to and compared against `.devaloy-bootstrapped` becomes
   `${TOOLSET_REVISION}` or `${TOOLSET_REVISION}+paseo`. Comment why: a plain
   revision number cannot express an optional tool, and the gate would otherwise
   skip forever on a volume provisioned before the key was flipped.
3. Add `mise use -g "npm:@getpaseo/cli@${MISE_PASEO_VERSION}"` inside a
   `WITH_PASEO` conditional, above `mise install`. Keep it one contiguous block
   with a comment marking its boundaries, so removing Paseo later is deleting
   one unit.
4. `entrypoint.sh`: forward `WITH_PASEO` and `MISE_PASEO_VERSION` into the
   `as_dev` bootstrap call, alongside `MISE_NODE_VERSION` and
   `MISE_HERDR_VERSION`.
5. Verification gate: with `WITH_PASEO=true` on a cold volume,
   `paseo --version` works as `dev`. This is also where the scoped-package
   assumption gets tested, since `npm:@getpaseo/cli` is the first `@scope/name`
   package this repo asks mise for. With `WITH_PASEO=false`, `command -v paseo`
   finds nothing and the boot log is unchanged from today.
6. Verification gate for the marker: boot once with `false`, then set `true` and
   `docker compose up -d` with no `--build`. The bootstrap must re-run and
   install Paseo, and it must not move `claude`, `codex` or `herdr`. This is the
   case a plain revision marker gets wrong.

### Phase 2 — Launch and supervise the daemon

7. `entrypoint.sh`: add `write_secret PASEO_PASSWORD "${PASEO_PASSWORD:-}"`
   alongside the existing token calls, so the value reaches the daemon and the
   on-box CLI through the file that already carries `CLAUDE_CODE_OAUTH_TOKEN`.
8. Add a Paseo block after the Orca block and before the final `wait`. Set
   `PASEO_PORT=6767`.
9. Three guards, in order: `WITH_PASEO` is `true`; `paseo` resolves as the dev
   user; a tailnet IPv4 exists. Silent when the key is off. A warning when the
   key is on and the binary is missing. A warning when the IP is missing, with
   the same "fix the tailscale failure above" line the Orca block uses.
10. When `WITH_PASEO_WEB_UI` is `true` and `PASEO_PASSWORD` is empty, log a
    warning naming the exposure, then start with the web UI anyway. Degrade
    nothing.
11. Launch in a backgrounded subshell that first writes `-250` to
    `/proc/self/oom_score_adj`, then runs an unbounded restart loop with a 10
    second backoff sleep.
12. The command string, run through `as_dev`, sources `~/.devaloy_secrets` and
    then runs `paseo daemon start --foreground --no-relay --listen
    "${PASEO_IP}:${PASEO_PORT}"`. Append `--web-ui --hostnames
    "${TS_HOSTNAME},.ts.net"` when `WITH_PASEO_WEB_UI` is `true`.
13. Log a connection hint the way the Orca block does, naming the host, the
    port, and that the mobile app wants **Settings → Add host → Direct
    connection** with SSL off.
14. Verification gate: `ss -ltn` inside the container shows the daemon on the
    tailnet IP and **not** on `0.0.0.0`; `cat /proc/$(pgrep -f 'Paseo
    Supervisor' | head -1)/oom_score_adj` reads `-250`; and `paseo provider
    diagnostic claude` reports a resolved binary and a non-empty model list,
    which is what proves both the `link-shims` PATH and the secrets sourcing in
    step 12.

### Phase 3 — Compose and `.env.example`

15. `docker-compose.yml`: add `WITH_PASEO`, `WITH_PASEO_WEB_UI`,
    `PASEO_PASSWORD` and `MISE_PASEO_VERSION` to the `environment:` list with
    defaults. These are environment variables, not `build.args`. Comment the
    contrast with `WITH_ORCA` directly, because a reader who has just read the
    `build:` block ten lines above will assume this needs `--build` too.
16. Extend the `ports:` comment. It currently explains the 6768 nuance for Orca.
    Paseo's 6767 is the counter-example: it binds the tailnet address only and
    is not reachable from the Docker host, and the comment should say why the
    two differ rather than leaving a reader to assume they behave alike.
17. `.env.example`: a commented block for the four keys, next to the existing
    `WITH_ORCA` block, stating that this one needs no `--build`.

### Phase 4 — Documentation

18. `README.md`: a "(Optional) the Paseo apps" section mirroring the Orca one.
    It must say, explicitly:
    - the key is a runtime variable, so `docker compose up -d` is enough;
    - `WITH_PASEO=false` stops the daemon and removes neither the CLI nor
      `~/.paseo`;
    - the relay is deliberately disabled and what that costs you;
    - `PASEO_PASSWORD` is optional, daemon-wide, and setting it makes the phone
      ask for it too;
    - the web UI is a second key, it is served with or without a password, and
      leaving the password empty means anything on your tailnet gets a full
      browser client;
    - Paseo injects its orchestration tools into every agent it launches;
    - workspace service previews do not work, because their `*.localhost` names
      do not resolve from the tailnet.
19. Update the capability table near the top of the README, and the
    `orca-cli`/`orcakit` paragraph, which currently describes the box's remote
    runtime story as Orca-only.
20. `docs/wiki/reference.md`: rows in the environment variable tables for the
    four keys. `WITH_PASEO` goes under a runtime section, **not** under "Build
    arguments" where `WITH_ORCA` lives.
21. `docs/wiki/connect-the-paseo-apps.md`: a how-to page matching the shape of
    `pair-the-orca-apps.md`, covering the mobile direct connection, the CLI
    `--host` form, the optional web UI, and a "What does not work" section for
    service previews. Register it in `docs/wiki/.wikimap.yaml` as an adopted
    how-to documenting `entrypoint.sh`, `bootstrap-toolchain.sh`,
    `docker-compose.yml` and `.env.example`.

### Phase 5 — Prove it end to end

22. Cold boot on an empty volume with `WITH_PASEO=true`: the box joins the
    tailnet, the bootstrap installs the CLI, the daemon binds the tailnet IP.
23. Boot once with the default `WITH_PASEO=false` and confirm the log is clean.
    No warnings, no missing-binary noise.
24. Connect the mobile app by direct connection and run a Claude Code agent.
    This is what catches a credential regression, not just a bind.
25. Run a Codex agent too. The two authenticate differently and only one of them
    is covered by `~/.devaloy_secrets`, so Codex inheriting its own `~/.codex`
    state through `HOME` is an assumption this step exists to test.
26. `SIGKILL` the supervisor and confirm the restart loop recovers within one
    backoff, rather than looping on a stale PID lock under `~/.paseo`.
27. `docker compose down && up` and confirm the connection survives without
    reconfiguring the phone, which proves the `PASEO_HOME` assumption.
28. Read `docker compose logs devaloy` after an idle hour. If the daemon's
    `info` output buries the entrypoint's own boot narrative, set
    `PASEO_LOG_CONSOLE_LEVEL=warn` and say so in the QA document.
29. Flip `WITH_PASEO` to `false`, `docker compose up -d`, and confirm the daemon
    is gone, the CLI is still installed, and the box is otherwise untouched.
30. On a box built `WITH_ORCA=true`, confirm both runtimes coexist on 6768 and
    6767.
31. Write it up in `docs/qa/` following the existing QA documents' format.

### Alternatives rejected

- **A build argument, mirroring `WITH_ORCA`.** The reason `WITH_ORCA` is a build
  argument does not exist here. There is no image payload to gate, and making
  this one a build argument would cost a rebuild to flip for no benefit.
- **A second marker file for optional tools.** Two gates that can disagree about
  the same volume, to avoid a re-run that costs nothing.
- **Installing from `entrypoint.sh` on a presence check.** Splits the tool list
  across two files, which `bootstrap-toolchain.sh`'s header comment exists to
  prevent.
- **The official `ghcr.io/getpaseo/paseo` image as a second service.** It would
  be a second container with a second home directory and no access to this box's
  toolchain, credentials or worktrees. devaloy is the development environment;
  Paseo is meant to run inside it, not beside it.
- **Binding `0.0.0.0`, as Orca does.** That was accepted for Orca because
  upstream offers no bind flag. Paseo defaults to loopback and takes an address,
  so taking the worse position on purpose would be indefensible.
- **Enabling the relay.** It is the fastest path to a phone with no Tailscale,
  and it is the one thing that would make the "no remote reach except the
  tailnet" claim false. Revisit only as a separately named opt-in key.
- **Refusing to start the daemon when the web UI key is set without a
  password.** One wrong key would cost the whole runtime, including mobile
  access that worked yesterday. Degrade the feature, never the runtime.
- **Launching through `zsh -lc` to pick up secrets.** Re-introduces the login
  shell `as_dev` deliberately avoids, during the same boot in which the
  entrypoint is rewriting those startup files.
- **A watchdog for the tailnet IPv4.** Real machinery for an event that a stable
  node identity makes rare, and the container restart already fixes it.

## Open questions

None. Every branch of the design tree was settled on 2026-08-19. The
assumptions that remain are build-time observations, each with a named
verification gate above: the mise npm backend accepting a scoped package
(step 5), stale PID lock behaviour after `SIGKILL` (step 26), Codex credential
inheritance (step 25), and console log volume (step 28).

## Non-goals

- **Public internet exposure.** No `ports:`, no reverse proxy, no TLS. Tailnet
  only, same as everything else here.
- **The Paseo relay.** Deliberately disabled, not merely left at its default.
- **Workspace service previews.** The proxy works; the `*.localhost` hostnames
  it routes on do not resolve from a phone, and fixing that needs wildcard DNS
  the tailnet does not provide.
- **Replacing Orca or Tailscale SSH.** Paseo is additive. SSH stays the primary
  and the recovery path, and `wait` stays on `tailscaled`.
- **Paseo's orchestration skills.** `npx skills add getpaseo/paseo` would fork
  the skill story this box already has, which installs everything from
  `mimukit/skills`. Separate decision, separate change.
- **Voice, Hub, and plugins.** Real Paseo features, none of them needed to reach
  a phone, and each carries its own credentials or network reach.
- **Paseo on by default.** `WITH_PASEO=false` is the default, like `WITH_ORCA`.
  This is an opt-in capability, not part of devaloy's baseline.
