# Plan: the T3 Code server on devaloy
Grilled: 2026-10-09

Drafted: 2026-10-09

## Context

[T3 Code](https://github.com/pingdotgg/t3code) (MIT, npm package `t3`) is a GUI control surface for coding agents. One server owns the providers, the files and the durable state, and clients connect to it over HTTP and WebSocket: the Electron desktop app, the iOS and Android apps, and the hosted web app at `app.t3.codes`. It drives Codex, Claude Code, Cursor, OpenCode, Grok Build and a few others through the CLIs already on the host.

devaloy already hosts two client families of this kind. Orca is a build argument (`WITH_ORCA`, a 154 MB `.deb` baked into the image). Paseo is a runtime key (`WITH_PASEO`, an npm package installed by mise into the home volume). T3 Code would be the third, and its shape matches Paseo almost exactly:

| | Paseo | T3 Code |
|---|---|---|
| Artifact | `npm:@getpaseo/cli` | `npm:t3`, bin `t3`, Node `^22.16 \|\| ^23.11 \|\| >=24.10` |
| Headless command | `paseo daemon start --foreground` | `t3 serve` ("without opening a browser and print headless pairing details") |
| Default bind | `127.0.0.1:6767` | `127.0.0.1:3773`, `--host` and `--port` (or `T3CODE_HOST`, `T3CODE_PORT`) widen it |
| Auth | `PASEO_PASSWORD`, daemon-wide | one-time pairing links exchanged for scoped sessions; no static token |
| State | `~/.paseo` | `~/.t3` (`T3CODE_HOME`): `userdata/statev2.sqlite`, `settings.json`, `logs/`, `worktrees/` |
| Own service manager | yes, PID lock | `t3 service install` needs systemd user units, which this box does not have |

Upstream calls the project "very very early". Stable releases land about weekly (v0.0.45 on 2026-10-02), and a client refuses a server on a different orchestration protocol version.

Success looks like this: `WITH_T3CODE=true` in `.env`, `docker compose up -d` with no `--build`, and two clients reach the box over Tailscale:

- The T3 Code desktop app on the laptop pairs with `http://<tailnet-ip>:3773` and runs a Claude Code thread on the box.
- The T3 Code mobile app on the phone pairs with the same address and opens that same thread.

The thread keeps running while the laptop sleeps, and the phone can follow it. No `ports:` key is added, and turning the key off stops the server on the next boot.

## How the clients reach the server

Both clients connect directly to the server over the tailnet, with plain HTTP. Upstream supports this route: `docs/user/remote-access.md` ("Pair over a LAN or private network") tells a command-line host to run `t3 serve --host <private-ip>` with the host's "LAN or tailnet address". The mobile app accepts cleartext HTTP on purpose. Its iOS build sets `NSAllowsArbitraryLoads: true` and asks for local network access "to connect to T3 Code servers on your local network or tailnet" (`apps/mobile/app.config.ts:266-271`), and its Android build sets `android:usesCleartextTraffic="true"` (`apps/mobile/plugins/withAndroidCleartextTraffic.cjs`). The upstream docs add: "On mobile, an IP address entered without a scheme uses HTTP."

The traffic is still encrypted, because WireGuard carries every tailnet packet. HTTPS would add a second layer only.

Each device pairs once with its own one-time link:

| Device | Prerequisite | How it pairs |
|---|---|---|
| Laptop | Tailscale on, same tailnet; T3 Code desktop app | Paste the pairing URL from the container log into **Settings → Connections → Add environment**. Optionally turn off **Local environment** to make the laptop a remote-only client. |
| Phone | Tailscale app on, same tailnet; T3 Code mobile app from the store (not a nightly server, which needs the beta app) | Run `ssh devaloy t3 pair` on the laptop and scan the QR code it prints, or paste the URL into **Settings → Environments → Add environment**. |

`t3 pair` finds the running server through `~/.t3/userdata/server-runtime.json` and builds the link from the bound host (`serverRuntimeState.ts`, `startupAccess.ts` `resolveHeadlessConnectionString`). With `--host 100.x.y.z` the link is `http://100.x.y.z:3773/pair#token=...`, so `ssh devaloy t3 pair` needs no wrapper. The server has no Host-header check outside dev mode, so `http://devaloy:3773` (MagicDNS) also reaches it. The apps add the box's Tailscale addresses as routes on their own once connected.

After pairing, the app saves the route and reconnects without a token. Revoking a device happens in **Settings → Connections** or with `t3 auth` on the box.

The tailnet policy must let the laptop and the phone reach `devaloy:3773`. The setup in `README.md:135-155` adds only an `ssh` rule and leaves the default allow-all access rule, which covers this. A policy with stricter `acls` or `grants` needs a rule for port 3773, and the docs say so.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Pattern to copy | Paseo, not Orca. `t3` is a plain npm package, so nothing justifies an image layer or a `--build`. |
| The key | `WITH_T3CODE`, a runtime environment variable, default `false`. It joins `WITH_PASEO` and `WITH_BROWSER` in `/opt/devaloy/runtime-flags` (`entrypoint.sh:480-489`), not in build-flags. |
| Install route | A new mise fragment `config/mise/optional/t3code.toml` declaring `"npm:t3" = "latest"`, copied into `~/.config/mise/conf.d/` by `bootstrap-toolchain.sh` exactly as `paseo.toml` is (148-155, 175-196). `devaloy update` upgrades it, and its `mise prune` removes it after the key turns off. The box's `node = "24"` satisfies the engines range once it resolves to 24.10 or later. |
| Version tracking | `latest`, refreshed only by `devaloy update`, as with Paseo. The boot path never upgrades. When an auto-updated app refuses the server on a protocol mismatch, the fix is `devaloy update`, and the docs say so. An exact pin was rejected: it would fall behind the store apps every week. |
| No pin variable | Same reason as Paseo: `MISE_T3_VERSION` would declare a non-registry tool named `t3` and break every mise call. To hold a version, edit the fragment. |
| Providers | Claude Code and Codex, the two CLIs devaloy already installs and logs in. T3 Code enables `codex` and `claudeAgent` by default and finds both on `PATH`. Other T3 Code providers need their CLI added through mise first, and are out of scope here. |
| Settings ownership | devaloy writes no T3 Code settings. `~/.t3/userdata/settings.json` belongs to the apps. There is no `config/t3code/` directory and no boot-time merge, unlike `config/paseo/config.json`. |
| Upstream installer and `t3 update` | Not used. `curl t3.codes/install.sh` writes to `~/.local/bin` outside mise, and `t3 update` would move the version behind mise's back. The docs say to use `devaloy update` instead. |
| Supervision | A restart loop in `entrypoint.sh`, modelled on the Paseo block (1088-1149): a background subshell with `oom_score_adj -250`, `as_dev`, the secrets snippet sourced, and `sleep 10` between restarts. `t3 service install` is out, because the container has no systemd. |
| Bind | `t3 serve --host <tailnet-ipv4> --port 3773 --no-browser`. Tailnet only, like Paseo, so port 3773 is not reachable on the Docker bridge. No compose `ports:` entry. It needs the tailnet IP and skips with a warning when there is none. |
| Client route | Direct pairing over the tailnet with plain HTTP, for both the laptop desktop app and the phone app. See "How the clients reach the server". |
| Tailscale HTTPS | Not in this plan. Neither client needs it, and `--tailscale-serve` would take port 443 on the node and need `tailscale set --operator=dev`. It returns only if the hosted web app at `app.t3.codes` becomes a goal. |
| Second device | `ssh devaloy t3 pair` on the running server issues a fresh link and a QR code with the tailnet address, so the phone does not need a server restart. No devaloy wrapper or TUI entry. The container log carries the first link and names this command. |
| Supervisor environment | `T3CODE_TELEMETRY_ENABLED=false`, so no analytics go to PostHog. `T3CODE_SERVER_BROWSER_SANDBOX=0`, because the container is already the isolation layer and Chrome's sandbox usually fails without user namespaces. No apt libraries are added for Chrome. If browser tabs fail on missing libraries, they stay broken and the docs say so. |
| Worktrees | One shared root, `~/worktrees/`, for Paseo and T3 Code. The entrypoint makes `~/.t3/worktrees` a symlink to `~/worktrees` when that path does not exist yet. If it is already a real directory, the entrypoint leaves it alone and logs one line. A symlink works on v0.0.45, which has no `worktreesDirectory` setting, and keeps the settings rule above intact. The two tools write into the same folder with no subfolder. A same-named worktree from both tools can collide, and that risk is accepted. |
| Restarts and running turns | A server restart (crash, `devaloy ram --t3`, container restart) cancels the agent turns that are running. Threads and history survive in SQLite. T3 Code's `continueThreadsAfterServerUpdate` setting resumes them, but it stays at its default (off) under the settings rule, and the docs tell you where to turn it on. A stale `server-runtime.json` after a crash does not block `t3 serve`; only `t3 start` checks it. |
| In-box agent guides | No change to `config/claude/CLAUDE.md` or `config/codex/AGENTS.md`. Agents on the box have no T3 Code tool to call. |
| Ordering | The block runs after `link-shims`, so `claude` and `codex` resolve inside the server's provider spawns. |
| Pairing | The server prints a pairing URL and a QR code to the container log on each start, as Orca does. |
| State | `~/.t3` on the existing `home` volume. No new volume. The first browser tab downloads about 120 MB of Chrome into `~/.t3/tools/`. |
| A missing binary | A fault, as with Paseo: `WITH_T3CODE=true` and no `t3` on `PATH` logs a warning that names `devaloy update`. |
| Coexistence | Orca (6768), Paseo (6767) and T3 Code (3773) can all run at once. Each is independent. |

Rejected alternatives:

- **No install at all.** The desktop app's "Add environment → SSH" downloads the server to `~/.t3/runtime` over Tailscale SSH. It costs nothing, but the desktop app then owns the server's version and lifetime, and the mobile apps have nothing to reach while the laptop sleeps. Worth one try during Phase 2 as a comparison, not as the design.
- **Release tarball in the Dockerfile, Orca style.** The tarball is a Node single executable with `SHA256SUMS`, which is attractive, but it needs a `--build` per weekly release and grows the image for a feature that is off by default.

## Approach

Copy the Paseo wiring key by key and keep each T3 Code piece next to its Paseo twin, so a reader finds both in one place. Reuse:

- `bootstrap-toolchain.sh` fragment staging and its hash marker (76-97, 157-166), so flipping the key forces a reinstall.
- `runtime_flag` in `lib/common.sh:230-245` and the runtime-flags file in `entrypoint.sh:480-489`.
- The Paseo supervisor shape in `entrypoint.sh:1088-1149` and its missing-binary warning (1277-1279).
- The `doctor_row` and `runtime_flag` pattern of the Paseo rows in `lib/doctor.sh:84-106`.
- The `paseo_pids` and `paseo_rss_mib` helpers in `lib/common.sh:137-196` as the template for `t3_pids`.

### Phase 1: install behind the key (built 2026-10-09)

- Add `config/mise/optional/t3code.toml` with a header comment in the style of `paseo.toml`.
- In `bootstrap-toolchain.sh`, read `WITH_T3CODE` through `runtime_flag`, stage the fragment when it is true, and add it to the `rm -f` list.
- Add `WITH_T3CODE` to the runtime-flags `printf` and to the bootstrap call's forwarded variables in `entrypoint.sh`.
- Add `WITH_T3CODE=${WITH_T3CODE:-false}` to `docker-compose.yml` with a comment, and a commented entry to `.env.example`.

Done when: with `WITH_T3CODE=true` and `docker compose up -d`, `ssh devaloy 't3 --version'` prints a version. With the key back to `false`, a restart plus `devaloy update` leaves `ssh devaloy 'command -v t3'` empty.

### Phase 2: supervise `t3 serve` (built 2026-10-09)

- Add a "T3 Code server" block to `entrypoint.sh` after the Paseo block. Gate it on `WITH_T3CODE=true` and `command -v t3`.
- Before the loop, make `~/.t3/worktrees` a symlink to `~/worktrees` when the path does not exist. Leave a real directory alone and log one line.
- Resolve the tailnet IPv4 and start the restart loop with `T3CODE_TELEMETRY_ENABLED=false T3CODE_SERVER_BROWSER_SANDBOX=0 t3 serve --host <ip> --port 3773 --no-browser`.
- Log the pairing URL and a one-line pointer to `ssh devaloy t3 pair` for the next device.
- Add the missing-binary warning next to the Paseo one.

Done when all of these hold:

- `docker compose logs devaloy` shows a pairing URL with the tailnet address and port 3773.
- The laptop desktop app pairs through that URL. A Claude Code thread and a Codex thread started from it both run on the box.
- `ssh devaloy t3 pair` prints a link with the tailnet address, not `127.0.0.1`.
- The phone, on Tailscale and off the home Wi-Fi (cellular data), pairs through that link and shows the same thread live.
- The thread keeps running with the laptop lid closed, and the phone follows it.
- A worktree created from the app lands under `~/worktrees/`, and `readlink ~/.t3/worktrees` prints the shared root.
- `docker compose exec devaloy pkill -f 't3 serve'` brings the server back within 15 seconds, and both apps reconnect without a new pairing.
- `curl http://<docker-bridge-ip>:3773` from the Docker host fails to connect.
- One browser tab opened from the app either works or fails with a logged library error. Phase 4 records which.

### Phase 3: doctor, status and RAM (built 2026-10-09)

- Add `t3_pids` and `t3_rss_mib` to `lib/common.sh`.
- Add two doctor rows, `t3 server` and `t3 cli`, with the same off, ok and broken rules as the Paseo rows.
- Add a status row in `lib/status.sh`, modelled on the Paseo row (50-65).
- Add a `--t3` restart option in `lib/ram.sh`, modelled on `--paseo`. It sends SIGTERM and warns that the restart cancels running turns.

Done when all of these hold:

- `devaloy doctor` shows `t3 server ok` and `t3 cli ok` with the key on, `off` with the key off, and `broken` with the key on and the server killed.
- `devaloy status` shows the server up with its RSS, and `DOWN` with the key on and no server.
- `devaloy ram --t3` restarts the server, prints the warning, and the apps reconnect.

### Phase 4: documentation and QA (built 2026-10-09)

- Add a README section "(Optional) the T3 Code apps" and a row in the optional-tools table.
- Add `docs/wiki/connect-the-t3-code-apps.md` and register it in `docs/wiki/.wikimap.yaml` and `docs/wiki/index.md`. It gives the laptop and the phone each a pairing procedure, the tailnet policy note for port 3773, and how to revoke a device. Its troubleshooting table covers a protocol mismatch (run `devaloy update`), cancelled turns after a restart (turn on `continueThreadsAfterServerUpdate` in the app), and the browser tab result from Phase 2.
- Add the key to the env table and port 3773 to the ports table in `docs/wiki/reference.md`.
- Add T3 Code to `docs/wiki/architecture.md`.
- Add a QA plan under `docs/qa/` with the next serial.

Done when: every new key, port and command in Phases 1 to 3 appears in the README and the wiki, and the QA plan runs clean on a fresh box.

## Open questions

None. The grill on 2026-10-09 settled every question. Phase 2 records one result rather than a decision: whether a browser tab works in this container.

## Non-goals

- T3 Connect (`t3 connect`), the hosted relay. Tailscale is the only route into the box.
- Tailscale HTTPS (`--tailscale-serve`) and the hosted web app at `app.t3.codes`, which needs it.
- Access from a device that is not on the tailnet.
- Nightly or preview channels.
- The desktop-managed SSH environment as a supported path.
- A Dockerfile change or a build argument, Chrome libraries included.
- T3 Code providers other than Claude Code and Codex.
- Any devaloy-managed T3 Code setting, `continueThreadsAfterServerUpdate` and `worktreesDirectory` included.
- A devaloy wrapper or TUI entry for `t3 pair`.
- Disk reclaim for `~/.t3/userdata/logs`, until the logs show growth.
- A note in the in-box agent guides.
- Fixing the stale Paseo docs found during research (for example `docs/wiki/manage-the-box.md:64` and the missing 6767 in the ports table). They belong in a separate change.
