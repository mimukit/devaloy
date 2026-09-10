# Plan: optional headless browser capture (`WITH_BROWSER`)

Drafted: 2026-09-07
Grilled: 2026-09-07

## Context

An agent on devaloy has no way to render a web page. It cannot check a UI change it just made, and it cannot show me what a page looks like. The fix is a headless Chromium driven by `playwright-cli`, which writes the screenshot to disk and prints the path. I open that path in Paseo, whose daemon runs in this same container and reads `/tmp` directly. Nothing is pushed anywhere and no port is published.

Success: on a box built with `WITH_BROWSER=true`, an agent runs `playwright-cli open <url>`, then `playwright-cli screenshot`, then `playwright-cli close`. The printed path is under `/tmp/playwright-cli`, the file exists, and it is a valid PNG. On a default build nothing changes: no Chromium libraries in the image, no npm package in the home volume, and the measured image size is the same as before.

## Verified during grilling

Read from the `@playwright/cli` 0.1.19 source (`playwright-core` 1.63.0-alpha) on 2026-09-07. Each one changed a decision below.

| Claim | Evidence |
|---|---|
| A bare `playwright-cli open` launches Google Chrome, not the bundled Chromium | `validateBrowserConfig` sets `channel = "chrome"` when none is given. `PLAYWRIGHT_MCP_BROWSER=chromium` maps to the bundled `chrome-for-testing` channel. |
| Playwright passes `--no-sandbox` by itself on Linux for the bundled Chromium | `chromiumSandbox` defaults to `false` when the channel is `chromium` or `chrome-for-testing`, and the launcher then pushes `--no-sandbox`. `PLAYWRIGHT_MCP_SANDBOX=true` sets it to `true`. |
| A bare `screenshot` writes to `.playwright-cli/page-<ts>.png` under the cwd | `PLAYWRIGHT_MCP_OUTPUT_DIR` moves the default. The only rejected value is `/`. `--filename` still overrides per call. |
| `playwright-cli install-browser` is `playwright install` under an alias | `installBrowser()` rewrites the argv and hands it to Playwright's own CLI. It skips a build already on disk and removes builds no installed Playwright links to, unless `--no-remove` is passed. `--only-shell` exists. |
| `install-browser chromium` fetches two builds | `browsers.json` lists `chromium` (Chrome for Testing) and `chromium-headless-shell`, both `installByDefault`, plus Playwright's own `ffmpeg` build for video recording. |
| The `.devaloy_env` heredoc in `entrypoint.sh` is single-quoted | No expansion inside it, so gated exports go in a second append after it. |
| Every `PLAYWRIGHT_MCP_*` variable is read from `process.env` for the CLI path | `configFromEnv(env ?? process.env)` feeds `resolveCLIConfigForCLI`. |

Still to verify on the box, in Phase 4: that `seccomp=unconfined` is enough for the sandbox, the size numbers, and the installer's skip and removal behaviour.

## Design decisions (settled)

| Decision | Resolution |
|---|---|
| Capture engine | `@playwright/cli` (binary `playwright-cli`). Not Playwright MCP, not chrome-devtools-mcp. It writes screenshots and snapshots to disk instead of streaming them into the agent's context. |
| Where the pieces live | Two halves, like Orca plus Paseo combined. The Chromium runtime libraries and `ffmpeg` are apt packages, so they go in the image behind a build arg. The npm package and the Chromium binary have no system dependency of their own, so they go in the home volume through mise and `playwright-cli install-browser`. |
| One key, two readers | A single `WITH_BROWSER` key in `.env`. Compose passes it as a build arg (the apt block) and as an environment variable (the bootstrap step and the entrypoint), the same split `WITH_DOCKER` already uses. |
| Default browser (Q1) | The entrypoint exports `PLAYWRIGHT_MCP_BROWSER=chromium` into `.devaloy_env`, only when `WITH_BROWSER=true`. No Google Chrome in the image, no per-call flag. |
| Sandbox (Q2) | The same block exports `PLAYWRIGHT_MCP_SANDBOX=true`. Chromium's own sandbox stays on. No `--no-sandbox` in our files, and Phase 4 checks the launched process, not the files. Compose already sets `seccomp=unconfined`, which is the user-namespace permission the sandbox needs, and the Orca block already runs on that claim. |
| Screenshot location (Q3) | The same block exports `PLAYWRIGHT_MCP_OUTPUT_DIR=/tmp/playwright-cli`, so a bare `screenshot` lands in `/tmp`. No new volume, nothing in `home`, no published port. `/tmp` is shared with the Paseo daemon in this container, so a path is all Paseo needs. Screenshots die with the container. |
| Browser binary location | Playwright's default, `~/.cache/ms-playwright`, inside the `home` volume. It survives a redeploy. |
| Which builds (Q4) | `playwright-cli install-browser chromium`, both builds. Record `du -sh ~/.cache/ms-playwright` in Phase 4. Switch to `--only-shell` later only if the number hurts and a shell launch is proven on the box. |
| Idempotent download and stale builds (Q7) | Rely on Playwright's installer. It returns at once when the wanted build is present, and it removes builds no installed Playwright links to. No hand-written directory guard, because a directory check would skip a needed download after `devaloy-update` moves `playwright-cli` to a version that wants a newer build. No prune step. |
| Shared memory (Q5) | `shm_size: ${DEVALOY_SHM_SIZE:-512m}`, not `ipc: host`. Playwright's Docker guide recommends `--ipc=host` because Chromium exhausts the 64 MB default `/dev/shm`. `shm_size` fixes the same crash without handing this container the host IPC namespace. Applied whether the browser is on or off, because an unwritten tmpfs costs nothing. |
| Missing-libraries warning (Q6) | `entrypoint.sh` probes `dpkg -s libnss3` when `WITH_BROWSER=true` and logs the `WITH_DOCKER` style warning that names `--build`. |
| Orphaned browsers (Q9) | No reaper. The README documents `close` as the third command and mentions `close-all`. The daemon inherits the shell's `oom_score_adj` of 0, so the OOM ladder kills it before tailscaled. |
| Docs scope (Q8, Q10) | No wiki task page. The README section documents the screenshot flow only, with one sentence that `ffmpeg` is present to convert the `video-stop` webm to GIF. |
| Off by default | `WITH_BROWSER` defaults to `false` everywhere: Dockerfile ARG, compose build arg, compose environment, `.env.example`. |
| No ntfy, no MCP | The push-notification wiring is untouched. No MCP server is installed. |

## Approach

The work reuses four existing patterns and adds nothing structurally new:

- The `WITH_ORCA` apt block in `Dockerfile` (contiguous, own comment, own cache mounts). The new block follows its shape.
- The `WITH_PASEO` block in `bootstrap-toolchain.sh` (a flag-gated `mise use`, and the flag folded into the revision marker so flipping the key re-runs the bootstrap).
- The `WITH_DOCKER` wiring in `docker-compose.yml`, where one `.env` key feeds both a build arg and an environment variable, and the `WITH_DOCKER` warning in `entrypoint.sh`.
- The `.devaloy_env` write and the `as_dev` bootstrap call in `entrypoint.sh`.

### Phase 1: the image (built 2026-09-07)

`Dockerfile`, one new block between the `WITH_DOCKER` block and the `COPY` lines.

1. Add `ARG WITH_BROWSER=false`.
2. Add a `RUN` gated on `[ "${WITH_BROWSER}" = "true" ]`, with the same two apt cache mounts, that installs the Chromium runtime set `playwright install-deps chromium` pulls on noble: libnss3, libnspr4, libatk1.0-0t64, libatk-bridge2.0-0t64, libcups2t64, libdrm2, libxkbcommon0, libxcomposite1, libxdamage1, libxfixes3, libxrandr2, libgbm1, libpango-1.0-0, libcairo2, libasound2t64. Add `ffmpeg` in the same list, for the GIF conversion. Playwright's own ffmpeg build only records.
3. Write the block comment in the Orca style: what it is, why it is not folded into the main list, OFF BY DEFAULT, build arg not runtime toggle, the measured size delta once known, and why the browser binary itself is not here (it belongs in the home volume, see Phase 2).
4. No `ldd` assertion is possible here, because no binary exists in the image. State that in the comment so nobody adds one later.

Verify: build with and without the arg, `docker image inspect --format '{{.Size}}'` for both, and `dpkg -l libnss3 ffmpeg` on the default build returns nothing.

### Phase 2: the toolchain (built 2026-09-07)

`bootstrap-toolchain.sh`.

1. Read `WITH_BROWSER="${WITH_BROWSER:-false}"` next to `WITH_PASEO`.
2. Fold it into the marker as a fixed-order composition, `<rev>[+paseo][+browser]`. `5+paseo`, `5+browser`, `5+paseo+browser` and `5` are all distinct, and a volume already at `5+paseo` still matches, so no box re-runs for nothing. Update the comment that explains why the marker records flags.
3. Add a contiguous `WITH_BROWSER` block after the Paseo block with `mise use -g npm:@playwright/cli@latest`. Same reasoning as Paseo: an npm package in the home volume, and turning the key off does not uninstall it.
4. After `mise install` and the `export PATH` for shims, gated on the same flag, run `playwright-cli install-browser chromium`. It lands in `~/.cache/ms-playwright`. The comment says the installer skips a present build and removes unlinked ones, so there is no guard and no prune. Fatal, like the skills install: a half-downloaded browser must not write the marker.
5. Do not bump `TOOLSET_REVISION`. The flag in the marker is what invalidates an existing volume. A bump would re-resolve every `@latest` tool on every box for a feature most boxes leave off.

Verify on a fresh `home` volume: the boot log shows the download once, and a second boot skips it.

### Phase 3: compose, entrypoint, env (built 2026-09-07)

1. `docker-compose.yml`: add `WITH_BROWSER: ${WITH_BROWSER:-false}` under `build.args` with a comment in the `WITH_DOCKER` style, and `WITH_BROWSER=${WITH_BROWSER:-false}` under `environment` with a comment that says the build arg puts the libraries in the image and this one makes the bootstrap install the CLI and the browser and makes the entrypoint export the three defaults. Add `shm_size: ${DEVALOY_SHM_SIZE:-512m}` next to the resource ceilings, with a comment that names the trade against `ipc: host`, the 64 MB Docker default, and that `/dev/shm` is a tmpfs that costs memory only when written to.
2. `entrypoint.sh`, three edits. Forward `WITH_BROWSER='${WITH_BROWSER:-false}'` in the `as_dev` call that runs the bootstrap, next to `WITH_PASEO`. After the `.devaloy_env` heredoc, when `WITH_BROWSER=true`, append a commented block that exports `PLAYWRIGHT_MCP_BROWSER=chromium`, `PLAYWRIGHT_MCP_SANDBOX=true` and `PLAYWRIGHT_MCP_OUTPUT_DIR=/tmp/playwright-cli`, with one line each on why (default channel is Chrome, Playwright drops the sandbox by default, default output dir is the cwd). When `WITH_BROWSER=true` and `dpkg -s libnss3` fails, log the `WITH_DOCKER` style warning that says the key is also a build arg and names `--build`.
3. `.env.example`: add `# WITH_BROWSER=false` with a comment block in the file's style (what it does, that it is BOTH a build arg and a runtime key, where the screenshot goes, how to hand the path to Paseo, that `close` ends the browser), and `# DEVALOY_SHM_SIZE=` under the resource ceilings.

Verify: `docker compose config` shows the arg, the env var and `shm_size` resolved. On the box, `df -h /dev/shm` shows 512M and `env | grep PLAYWRIGHT_MCP_` shows the three exports.

### Phase 4: verification on the box (built 2026-09-07)

Build with `WITH_BROWSER=true` and start the box. From a shell on it:

1. `playwright-cli open https://example.com`, then `playwright-cli screenshot`. The printed path is under `/tmp/playwright-cli`. Confirm the directory is created by Playwright and owned by `dev`, or add a `mkdir` to the entrypoint block if it is not.
2. `file <path>` reports PNG image data.
3. Sandbox check, while the browser is open: `ps -o args= -C chrome | grep -c -- --no-sandbox` prints `0` and the capture in step 1 succeeded. From the dev shell, `grep Seccomp /proc/self/status` reads `0` under runc. Record the result in the entrypoint block comment and in the architecture page. Then `playwright-cli close`.
4. `du -sh ~/.cache/ms-playwright`. Record the number in the bootstrap comment and the reference page.
5. Second boot on the same volume: the log shows no download.
6. Record the image sizes from Phase 1 in `Dockerfile`, `docker-compose.yml`, `.env.example` and `docs/wiki/reference.md`, the way the Orca and Docker numbers are recorded.
7. Rebuild with `WITH_BROWSER` unset. `dpkg -l | grep -c 'libnss3\|ffmpeg'` prints `0`, and `env | grep -c PLAYWRIGHT_MCP_` prints `0`.

### Phase 5: docs (built 2026-09-07)

Follow the repo's wikikit rules: commands verified against the code, and the `_Verified against main@<sha>_` line refreshed on each page touched.

1. `README.md`: a new `Optional` row in the "What's on the box" table, and a short `## (Optional) headless browser capture` section after the Docker one. The section covers the key, the `--build` need, the three-command capture (`open`, `screenshot`, `close`), `close-all` for a forgotten session, how to open the path in Paseo, and one sentence that `ffmpeg` is there to convert a `video-stop` webm to GIF.
2. `docs/wiki/reference.md`: `WITH_BROWSER` in the Build arguments table with the measured delta, `WITH_BROWSER` in the environment variables with the "one key, two readers" note next to the `WITH_DOCKER` one, `DEVALOY_SHM_SIZE` under Resource ceilings, `playwright-cli` under Commands on the box, and the three `PLAYWRIGHT_MCP_*` exports under Managed files as lines `.devaloy_env` carries.
3. `docs/wiki/architecture.md`: the image row of "Three layers of state" gains "optionally the Chromium runtime libraries", the `home` row gains "the Chromium binary under `~/.cache/ms-playwright`", and a new row for `/tmp` that says screenshots live there and die with the container. A short `## The optional browser capture` section after the Docker one records the sandbox verification, why the three exports exist, and the `shm_size` trade.
4. `docs/wiki/index.md`: no change. No task page.

## Deviations during the build

| Plan said | Built | Why |
|---|---|---|
| `mise use -g npm:@playwright/cli@latest` | Pinned to `0.1.18` | mise's npm backend refuses 0.1.19 as a trust downgrade: releases 0.1.0 to 0.1.18 carry npm provenance from GitHub Actions, and 0.1.19 was published by hand from Microsoft's npm account with none. The pin is the newest release with provenance. No trust-policy exclusion and no shell-out to npm, because either would waive the check for every later release. Move the pin by hand when provenance returns. |

Measured on arm64 with Docker 29, 2026-09-07: image 660 MB off and 1.09 GB on; browser cache 982 MB (642 MB Chromium, 337 MB headless shell, 3 MB Playwright's ffmpeg); first download 330 s, second run 1 s; 8 Chromium processes with `--no-sandbox` without the sandbox export, 0 with it; `Seccomp: 0`; Playwright created `/tmp/playwright-cli` itself, owned by `dev`; Playwright launched the full Chromium build, so `--only-shell` is ruled out.

## Open questions

None. Two facts are left for Phase 4 rather than for a decision: whether Playwright creates `/tmp/playwright-cli` itself, and the measured sizes.

## Non-goals

- No `--no-sandbox`, no `ipc: host`, no `privileged` change, no new capability.
- No Google Chrome in the image. The bundled Chrome for Testing build is the browser.
- No new volume, no writes to the `home` volume for screenshots, no published port.
- No Playwright MCP, no chrome-devtools-mcp, no MCP server of any kind.
- No idle reaper for forgotten browser sessions.
- No wiki task page, no GIF recipe in the docs.
- No change to the ntfy or push-notification wiring.
- No Firefox or WebKit. Chromium only.
- No commit. The work stays uncommitted for review.
