# Reference

Declared surface only: the variables, commands, flags and managed paths this
repo defines in one place. For what any of it is *for*, see
[Architecture](architecture.md).

## Environment variables

All are set in `.env` beside `docker-compose.yml`, and every one is optional
except `TS_AUTHKEY` on a first boot.

### Identity

| Variable | Default | Effect |
|---|---|---|
| `DEVALOY_NAME` | `devaloy` | Names the box everywhere it can collide: `container_name`, `hostname`, the compose project name (so the `home`, `tailscale-state` and `docker-data` volume prefixes), and the `TS_HOSTNAME` default. Set it to run a second devaloy on one host. Under Dokploy the volume prefix comes from the app name via `-p` instead, and this key governs the rest. |

### Tailscale

| Variable | Default | Effect |
|---|---|---|
| `TS_AUTHKEY` | empty | Auth key for joining the tailnet. Must be **reusable, non-expiring and untagged**. Optional on a redeploy — the node identity is already in the `tailscale-state` volume. |
| `TS_HOSTNAME` | `DEVALOY_NAME` (`devaloy`) | Node name on the tailnet, and the name given to the signing key registered on GitHub. Set it only when the tailnet name must differ from the container name; otherwise let `DEVALOY_NAME` drive it. The name is global to the tailnet, so two boxes that share one join as `<name>` and `<name>-1`. |
| `TS_ACCEPT_DNS` | `false` | `true` passes `--accept-dns=true`. Letting Tailscale rewrite `/etc/resolv.conf` inside a container clobbers Docker's resolver — turn it on only if you need MagicDNS resolution *from* the box. |

### Credentials

| Variable | Default | Effect |
|---|---|---|
| `GITHUB_TOKEN` | empty | Authenticates `gh` and `git push` over HTTPS from first boot. Written to `~/.devaloy_secrets` **and** stored via `gh auth login --with-token`. |
| `CLAUDE_CODE_OAUTH_TOKEN` | empty | Authenticates Claude Code with no interactive `/login`. Generate with `claude setup-token` on a machine that has a browser. |
| `CODERABBIT_API_KEY` | empty | Authenticates the CodeRabbit CLI (`coderabbit`, `cr`). Generate it in the CodeRabbit web app under Organization Settings → API Keys. Stored with `cr auth login --api-key` into `~/.coderabbit/auth.json`, and written to `~/.devaloy_secrets` for a hand-passed `--api-key`. The CLI does not read the variable at review time. |
| `GIT_AUTHOR_NAME` | empty | `user.name`. Falls back to the `GITHUB_TOKEN` account's name. |
| `GIT_AUTHOR_EMAIL` | empty | `user.email`. Falls back to that account's `ID+login@users.noreply.github.com` address. |
| `GIT_SIGNING_SSH_KEY` | empty | Base64 of a **passphrase-less OpenSSH private key**. Enables SSH commit and tag signing. |
| `DEVALOY_REPOS` | empty | Whitespace-separated repos to clone into `~/projects` on each boot. See [Cloning repos on boot](#cloning-repos-on-boot). |

Clearing any of these and redeploying **revokes** it: `~/.devaloy_secrets`,
`~/.config/gh/hosts.yml`, `~/.config/agent-push.env` and the signing key are all
deleted and rebuilt from scratch on every boot.

`GIT_SIGNING_SSH_KEY` wants the **private** half. A correct value runs to several
hundred characters and decodes to a `BEGIN OPENSSH PRIVATE KEY` block; anything
near a hundred characters is the public half and is rejected at boot. Literal PEM
is also accepted, for the case where the value arrives through some channel that
can carry newlines.

### Cloning repos on boot

`DEVALOY_REPOS` seeds `~/projects` so a fresh box starts on real code. The list lives in `.env`, which is gitignored, so no repo of yours is named in this repository. Entries are separated by whitespace, and each one takes one of three forms:

| Form | Example | Clones to |
|---|---|---|
| `owner/repo` | `mimukit/devaloy` | `~/projects/devaloy` |
| `https://` URL | `https://github.com/cli/cli` | `~/projects/cli` |
| `git@host:path` | `git@github.com:you/private.git` | `~/projects/private` |

A trailing `.git` or `/` is stripped before the directory is named. Cloning goes over HTTPS through the credential helper that `gh auth setup-git` installs, so a private repo needs `GITHUB_TOKEN`. The `git@` form needs an SSH key on the box, which devaloy does not install for you.

The step runs on every boot and is idempotent. A repo already cloned in `~/projects` is left alone and logs nothing, so adding an entry and redeploying clones only that one. Nothing is ever pulled, updated or deleted; `git pull` stays yours to run.

Failures never stop the box. An entry with an illegal character, an unrecognized form, a failed clone, or a name already taken by something that is not a clone logs one `[entrypoint] WARNING` line and the rest of the list continues. Two repos of the same name from different owners hit that last case: the second is skipped, and you clone it by hand under another name.

### Push notifications

Off entirely unless `NTFY_TOPIC` is set. Full behavior is in
[Push notifications](push-notifications.md).

| Variable | Default | Maps to |
|---|---|---|
| `NTFY_TOPIC` | empty | `PUSH_NTFY_TOPIC` — **this string is the credential**; make it long and random |
| `NTFY_SERVER` | empty | `PUSH_NTFY_URL` |
| `NTFY_TOKEN` | empty | `PUSH_NTFY_TOKEN` |

### Paseo daemon

Off by default. See [Connect the Paseo apps](connect-the-paseo-apps.md).

| Variable | Default | Effect |
|---|---|---|
| `WITH_PASEO` | `false` | Installs the `paseo` CLI through mise, writes `~/.paseo/config.json`, and starts the daemon on `<tailnet-ip>:6767`. A **runtime** variable, unlike `WITH_ORCA` — `docker compose up -d` picks up a change with no `--build`. Setting it back to `false` stops the daemon; it uninstalls nothing and stops rewriting the config. |
| `WITH_PASEO_WEB_UI` | `false` | Sets `features.webUi.enabled`, serving a browser client from the daemon's origin. Static files load without auth. |
| `PASEO_PASSWORD` | empty | Optional, and **daemon-wide** rather than web-UI only: setting it makes the phone's direct connection ask for it too. Written to `~/.devaloy_secrets` (0600), never to the config file — `daemon.auth.password` takes a bcrypt hash only. Empty with `WITH_PASEO_WEB_UI=true` logs a warning and serves anyway. |
| `PASEO_PLUGINS` | empty | Plugins to install once the daemon answers. Whitespace-separated; each entry is a git source (`owner/repo:plugins/name`) or a directory on the box, optionally prefixed `id=`. A plugin whose id is already installed is skipped. |

Flipping `WITH_PASEO` re-runs the toolchain bootstrap, because the revision
marker records the key alongside the revision (`5` vs `5+paseo`). The boot path
installs and never upgrades, so nothing already on the volume moves.

The daemon takes no command-line settings. They live in `~/.paseo/config.json`,
which every `paseo` on the box reads too, and which the entrypoint rebuilds on
each boot from three layers: the file already in the `home` volume, then
`config/paseo/config.json` from the repo, then the values derived from the
container.

| Key | Layer | Value |
|---|---|---|
| `daemon.listen` | container | `<tailnet-ip>:6767` |
| `daemon.hostnames` | container | `["${TS_HOSTNAME}", ".ts.net"]` |
| `features.webUi.enabled` | container | `WITH_PASEO_WEB_UI` |
| `daemon.relay.enabled` | repo | `false` |
| `daemon.cors.allowedOrigins` | repo | `["https://app.paseo.sh"]` |
| `worktrees.root` | repo | `~/worktrees/` |
| `daemon.agentProfiles` | repo | manager, thinker, worker, thinker cx, worker cx |
| `daemon.terminalProfiles` | repo | Claude Code, Codex, Lazygit |

Objects merge key by key and arrays are replaced whole, so a key the repo does
not ship survives a redeploy, and every key in the table above does not. Add a
profile in the app and the next boot drops it. Add it to
`config/paseo/config.json` and it holds. See
[Connect the Paseo apps](connect-the-paseo-apps.md) for the profile lists.

### Toolchain pins

| Variable | Default | Effect |
|---|---|---|
| `MISE_NODE_VERSION` | `24` | Node **major**, not mise's floating `lts` alias — that alias rolls across majors. |
| `MISE_HERDR_VERSION` | `latest` | Pin herdr. |
| `CODERABBIT_VERSION` | `latest` | Pin the CodeRabbit CLI, for example `v1.2.3`. Not a `MISE_*` name on purpose — mise reads any `MISE_<TOOL>_VERSION` as a tool declaration, and there is no `coderabbit` in its registry. |

Everything else in the toolchain (`pnpm`, `gh`, `turbo`, `lazygit`, `claude`,
`codex`, `command-code`, `skills`, `@getpaseo/cli`) tracks `latest` and is pinned by editing
`bootstrap-toolchain.sh`, not by a variable.

Do not add a variable here whose tool name is not a real mise registry entry.
mise reads every `MISE_<TOOL>_VERSION` in its environment as a declaration of a
tool called `<TOOL>`, so an unknown name makes every `mise` command on the box
fail. `MISE_PASEO_VERSION` did exactly that: Paseo ships as
`npm:@getpaseo/cli`, there is no `paseo` in the registry, and the toolchain
bootstrap died at `mise use` on every boot.

### Resource ceilings

All off by default. See [Size the container resource limits](vm-resource-limits.md).

| Variable | Default | Compose key |
|---|---|---|
| `DEVALOY_MEM_LIMIT` | `0` (unlimited) | `mem_limit` |
| `DEVALOY_MEMSWAP_LIMIT` | `0` (2× `mem_limit`) | `memswap_limit` |
| `DEVALOY_MEM_RESERVATION` | `0` | `mem_reservation` |
| `DEVALOY_CPUS` | `0` (unlimited) | `cpus` |
| `DEVALOY_CPU_SHARES` | `1024` | `cpu_shares` |
| `DEVALOY_PIDS_LIMIT` | `-1` (unlimited) | `pids_limit` |
| `DEVALOY_SHM_SIZE` | `512m` | `shm_size` |

`DEVALOY_SHM_SIZE` is the one with a real default. Docker's own is 64 MB, and a
headless Chromium crashes at that on a heavy page; Playwright's advice is
`--ipc=host`, which would share the host's IPC namespace, and a bigger tmpfs
fixes the same crash without it. It costs nothing until written to, and then
counts against `DEVALOY_MEM_LIMIT`. Set whether `WITH_BROWSER` is on or off.

### Nested Docker

Both grant the container authority over its own namespaces, which is what a
nested `dockerd` needs. Set **one**, never both. See
[Prepare a host for Sysbox](prepare-a-host-for-sysbox.md).

| Variable | Default | Compose key | Effect |
|---|---|---|---|
| `DEVALOY_RUNTIME` | `runc` | `runtime` | Set to `sysbox-runc` on a shared host. Needs Sysbox installed there first. No privilege is granted. |
| `DEVALOY_PRIVILEGED` | `false` | `privileged` | All-or-nothing: every host device, so an agent here can mount the host disk. Only on a host you own alone. |

`WITH_DOCKER` is the third key and it is a build argument, listed below.

### Browser capture

| Variable | Default | Effect |
|---|---|---|
| `WITH_BROWSER` | `false` | The runtime half of the build argument of the same name. Makes the bootstrap install `playwright-cli` (pinned, see below) and download a Chromium into `~/.cache/ms-playwright`, and makes the entrypoint export the three `PLAYWRIGHT_MCP_*` defaults into `~/.devaloy_env`. Warns at boot when the image was built without the libraries. |

Flipping it re-runs the toolchain bootstrap, because the revision marker
records the flag the way it records `WITH_PASEO`.

The three exports, only present when the key is on:

| Export | Value | Why |
|---|---|---|
| `PLAYWRIGHT_MCP_BROWSER` | `chromium` | The CLI defaults to Google Chrome, which the image does not carry. |
| `PLAYWRIGHT_MCP_SANDBOX` | `true` | Playwright launches the bundled Chromium with `--no-sandbox` on Linux unless told otherwise. Measured: 8 Chromium processes carry the flag without this export, 0 with it. |
| `PLAYWRIGHT_MCP_OUTPUT_DIR` | `/tmp/playwright-cli` | A bare `screenshot` would otherwise write into `.playwright-cli/` under the current directory. |

## Build arguments

| Argument | Default | Effect |
|---|---|---|
| `WITH_ORCA` | `false` | Builds in the `orca serve` runtime. Takes the image from 683 MB to 1.6 GB on arm64. |
| `WITH_DOCKER` | `false` | Builds in Docker Engine, CLI, Compose and buildx, and adds `dev` to the `docker` group. About +460 MB on arm64 (918 MB to 1.38 GB, measured with Docker 29). Needs `DEVALOY_RUNTIME` or `DEVALOY_PRIVILEGED` set as well, or the daemon will not start. |
| `WITH_BROWSER` | `false` | Builds in the shared libraries a headless Chromium needs, plus `ffmpeg`. About +430 MB on arm64 (660 MB to 1.09 GB, measured with Docker 29). The browser itself is not in the image: the same key, read at runtime, makes the bootstrap download it into the home volume (982 MB, measured). |

All three are read from `.env` like the variables above, but they are **build
arguments** — `docker compose up -d` alone will not pick up a change to any of
them. You need `docker compose up -d --build`. `WITH_BROWSER` is also read at
runtime, and is listed above for that half.

`WITH_PASEO` is the one to keep separate in your head. It looks like a sibling
and is not: it is an environment variable listed above, because Paseo installs
into the home volume rather than the image. It needs no `--build`.

Two more are pinned in the `Dockerfile` itself rather than exposed through
compose: `ORCA_VERSION` (`1.4.164`) and `ZSH_COMPLETIONS_VERSION` (`0.36.0`).
Changing either means editing the file and rebuilding.

## Commands on the box

Run as the `dev` user unless noted.

Every management verb belongs to one command, `devaloy`. The five older names are symlinks to it and still work; `devaloy` reads its own name to pick the verb. See [Manage the box](manage-the-box.md) for the picker and its keys.

| Command | Effect |
|---|---|
| `devaloy` | Opens the picker. With no terminal and no verb, prints `devaloy status` as plain text and exits `0`. Needs fzf 0.65+ to draw; below that it refuses and names `devaloy update`, while every verb still runs. Modules live in `/usr/local/lib/devaloy/`, overridable with `DEVALOY_LIB`. |
| `devaloy status` | Disk on the home volume, memory and swap against the container's ceiling, the Paseo daemon, Docker, and the toolset revision. |
| `devaloy doctor` | What this box was built with and what is working. Exits `1` only when a capability the image *was* built with is broken; absent by build flag exits `0`. Reads `/opt/devaloy/build-flags`, which the Dockerfile writes. |
| `devaloy update` (`devaloy-update`) | Re-runs the bootstrap with `--force`, refreshes the `/usr/local/bin` mirror, then runs `mise prune` to delete tool versions no tracked config still asks for. A failed prune warns and does not fail the update. Refuses to run as root. |
| `bootstrap-toolchain.sh` | Seeds `config/mise/` into `~/.config/mise` and installs the toolchain, but **skips itself** if the home volume already records the hash of that config. |
| `bootstrap-toolchain.sh --force` | Installs regardless, and additionally runs `mise upgrade` to re-resolve everything tracking `latest`. |
| `link-shims` | Mirrors mise's shims into `/usr/local/bin`. **Needs root.** Reads `DEV_HOME` (default `/home/dev`). Never clobbers a real file, only symlinks. |
| `devaloy nvim-sync` (`devaloy-nvim-sync`) | Copies the repo's LazyVim config from `/opt/devaloy/config/nvim` over `~/.config/nvim`, then runs a headless `Lazy! sync`. Moves the current directory to `~/.config/nvim.bak-<timestamp>` first, unless given `--no-backup`. Refuses to run as root. See [The editor config](#the-editor-config). |
| `devaloy prune` (`devaloy-prune`) | Reclaims disk from the nested Docker daemon. Only on a `WITH_DOCKER=true` build. **Reports by default; needs `--apply` to act** — a change from the old `devaloy-prune`, which pruned immediately. Takes `--all` (also images no container is running) and `--age <duration>` (default `168h`). Never touches a running container, and never runs on a timer. |
| `devaloy ram` (`devaloy-ram`) | Reclaims RAM inside the box. **Reports by default; needs `--apply` to act.** Restarts the Paseo daemon and its worker tree, and TERMs orphaned language servers (`ppid` 1, idle past `--age <minutes>`, default 60). Dev servers are listed, never killed. Takes `--paseo` or `--orphans` to run one half. Never touches `drop_caches`, which is not namespaced and would hit the whole host. |
| `devaloy disk` (`devaloy-disk`) | Reclaims disk from the home volume, which `devaloy prune` does not cover. **Dry run by default; needs `--apply` to act.** Removes `node_modules` untouched for `--age <days>` (default 30), prunes dead git worktree records, and with `--caches` prunes the pnpm/npm/turbo caches. `--docker` hands off to `devaloy prune`, and `mise prune` reaps the stale tool versions that are usually the largest share. Lists linked worktrees but never deletes one, since it cannot tell a stale checkout from uncommitted work. |
| `playwright-cli` | Drives a headless Chromium. Only with `WITH_BROWSER=true`. `open <url>`, `screenshot` (prints a path under `/tmp/playwright-cli/`), `close`; `close-all` ends every session. Pinned to `@playwright/cli` 0.1.18 in `bootstrap-toolchain.sh`, the newest release with npm provenance. |

Any argument to `bootstrap-toolchain.sh` other than `--force` exits `2` without
installing anything.

### Aliases

devaloy-specific, from `config/zsh/zshrc`. The file also carries the usual
`ll`/`gs`/`gd` shorthands, which are not listed here.

| Alias | Expands to |
|---|---|
| `update` | `devaloy update` |
| `skmi` | `skills add mimukit/skills --global --skill '*' -a claude-code -a codex -y` |
| `skup` | `skills update --global -y` |
| `clc` | `claude --model "claude-opus-5[1m]"` |
| `clcy` | `claude --allow-dangerously-skip-permissions` |
| `cx` | `codex` |
| `h` | `herdr` |
| `gg` | `lazygit` |
| `v` | `nvim`, or `vim` when `nvim` is not installed yet |
| `reload` | `exec zsh` |
| `zsrc` | `. "$HOME/.zshrc"` |

`skmi` is what picks up a **newly authored** skill. `skup` only refreshes what is
already in the lockfile, so it will never notice one that was not installed
before.

## The editor config

`v` opens Neovim with a LazyVim config, and `$EDITOR` points at the same binary, so `git commit` and `gh` open it too. Both fall back to stock `vim` when `nvim` is missing, which is only the case on a cold volume before the toolchain bootstrap has run.

The config is not upstream's LazyVim starter. It is a vendored copy of `mimukit/dotfiles:dot_config/nvim`, kept in this repo at `config/nvim/` and carried into the image at `/opt/devaloy/config/nvim`. It sets tokyonight with a transparent background, `scrolloff` 20, `;` for command mode, 2-space tabs, the snacks explorer on the right showing hidden and gitignored files, and the `lang.json`, `lang.toml` and `util.dot` LazyVim extras. `lazy-lock.json` is vendored with it, so a fresh box resolves the same plugin commits as the laptop.

**The seed runs once.** `bootstrap-toolchain.sh` copies `config/nvim/` into `~/.config/nvim` only when that directory does not exist. This is deliberate and it is why the copy does not go through `entrypoint.sh`, which re-copies the zsh, Claude Code and Codex files on every boot. Once seeded, `~/.config/nvim` is yours: edit it on the box and it survives every `docker compose up --build`, and `devaloy update` will not touch it.

To pull the repo copy back over your own, run `devaloy nvim-sync`. It moves the current directory to `~/.config/nvim.bak-<timestamp>` and prints the path, so a sync you did not mean to run costs nothing. Use it after changing `config/nvim/` in this repo, or on a box seeded before `config/nvim/` existed and still holding the plain starter.

To start over completely, delete the config and its state, then seed again:

```sh
rm -rf ~/.config/nvim ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim
devaloy nvim-sync --no-backup
```

**One divergence from the laptop.** The laptop config maps `<C-h/j/k/l>` to `Navigator.nvim`, which hops between Neovim splits and tmux panes with one key. That plugin is not in the spec, so the maps are dropped here rather than left to print `E492` on every press. LazyVim's own window maps take those keys instead, so split-to-split movement still works; the tmux pane hop and the terminal-mode variant do not. This is an omission on purpose, not an oversight.

## Commands on the Docker host

Both live in `scripts/`, which is excluded from the Docker build context — so
neither is in the image, and both are run on the host. Each has its own page:
[Lock down the host firewall](lock-down-the-host-firewall.md) and
[The host resource guard](host-resource-guard.md).

### `host-firewall-lockdown.sh`

Needs root. No flags. Refuses to run unless Tailscale is up on the host *and*
your SSH session came from a tailnet address.

| Variable | Default | Effect |
|---|---|---|
| `TS_IFACE` | `tailscale0` | Interface to allow traffic on |
| `ALLOW_NON_TAILNET` | unset | `1` overrides the second anti-lockout guard |

### `host-resource-guard.sh`

| Flag | Effect |
|---|---|
| `--check` | Report only. **Default. Writes nothing.** |
| `--apply` | Install and configure everything. Needs root. |
| `--restart-docker` | With `--apply`, also restart dockerd. **Bounces every container on the host.** |
| `--yes`, `-y` | Skip the confirmation prompt |
| `--sysbox` | Switch to Sysbox mode: report the host's subnets and daemon.json, and on `--apply` write only `bip` and `default-address-pools`. Never installs Sysbox, never removes a container. |
| `--bip CIDR` | With `--sysbox --apply`. The Docker default bridge address. **Required, no default.** |
| `--pool BASE/PREFIX/SIZE` | With `--sysbox --apply`. The pool user-defined networks come from. **Required, no default.** |
| `-h`, `--help` | Usage |

| Variable | Default |
|---|---|
| `SWAPPINESS` | `10` |
| `LOG_MAX_SIZE` | `10m` |
| `LOG_MAX_FILE` | `3` |
| `PRUNE_KEEP_HOURS` | `168` |
| `EARLYOOM_AVOID` | `^(sshd\|dockerd\|containerd\|tailscaled\|traefik\|mariadbd\|mysqld)$` |
| `EARLYOOM_PREFER` | `^(apache2\|node\|npm\|pnpm\|turbo\|esbuild)$` |
| `SYSBOX_BIP` | empty (same as `--bip`) |
| `SYSBOX_POOL` | empty (same as `--pool`) |
| `SYSBOX_VERSION` | `0.7.1` |

## Managed files

Written or overwritten by `entrypoint.sh` on **every boot**. Editing any of these
on the box is pointless — the change is gone at the next redeploy.

| Path | Mode | Contents |
|---|---|---|
| `~/.devaloy_env` | default | `PATH`, the mise release-age exclusion, sources `~/.devaloy_secrets`, resets `oom_score_adj`; plus the three `PLAYWRIGHT_MCP_*` exports when `WITH_BROWSER=true` |
| `~/.devaloy_secrets` | **600** | `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CODERABBIT_API_KEY`, `PASEO_PASSWORD` — each only written when set |
| `~/.config/agent-push.env` | **600** | `PUSH_NTFY_*` — only written when `NTFY_TOPIC` is set |
| `~/.coderabbit/auth.json` | **600** | The CodeRabbit credential, written by `cr auth login --api-key`. Deleted on every boot and rewritten only when `CODERABBIT_API_KEY` is set. |
| `~/.zshrc` | default | Copied from `config/zsh/zshrc` |
| `~/.ssh/devaloy_signing` | **600** | The private signing key. Its `.pub` is derived beside it at the default mode. |
| `~/.config/git/allowed_signers` | **600** | Local `git log --show-signature` only; GitHub does not read it |
| `~/.config/gh/hosts.yml` | — | Deleted unconditionally, then rewritten if `GITHUB_TOKEN` is set |

Merged rather than replaced, so files the repo does not ship survive:

| Path | Source |
|---|---|
| `~/.claude/` | `config/claude/` |
| `~/.codex/` | `config/codex/` |
| `~/.local/bin/` | `config/bin/` |
| `~/.claude.json` | `hasCompletedOnboarding` only, and only when `CLAUDE_CODE_OAUTH_TOKEN` is set |

Never touched:

| Path | Why |
|---|---|
| `~/.zshrc.local` | Your escape hatch, sourced last by `~/.zshrc` |
| `~/.claude/.credentials.json`, `~/.codex/auth.json` | Credentials the repo does not own |
| `~/.gitconfig` | Only the individual keys below are set, one at a time |

### git config keys the entrypoint owns

`user.name`, `user.email`, `gpg.format`, `user.signingkey`, `commit.gpgsign`,
`tag.gpgsign`, `gpg.ssh.allowedSignersFile`.

The last five are **unset** when no usable signing key is configured, so a box
that signed yesterday does not fail every commit today.

### Other paths

| Path | Notes |
|---|---|
| `~/.local/share/mise/shims` | Where the toolchain actually lives |
| `~/.local/share/mise/.devaloy-bootstrapped` | The toolset marker: 12 hex characters of a hash over the mise config the bootstrap installed, optional fragments included. Written last, and only on success. |
| `~/.cache/ms-playwright` | The Chromium builds `playwright-cli` launches. Only with `WITH_BROWSER=true`. In the home volume, so it survives a redeploy; Playwright's installer removes builds no installed release links to. |
| `/tmp/playwright-cli` | Where a bare `playwright-cli screenshot` writes. Created by Playwright on first use. Not a volume: gone with the container. |
| `/usr/local/bin` | The `link-shims` mirror. Outside the volume, so it is rebuilt each boot. |
| `~/.config/mise/config.toml` | The declared toolset, copied from `config/mise/config.toml` on each boot. A `mise use -g` here is overwritten by the next one. |
| `~/.config/mise/conf.d/` | The optional tools, one fragment per `WITH_*` key. Deleted when the key is off. |
| `/opt/devaloy/config` | The image's copy of `config/`, the source for the sync |
| `/var/lib/tailscale` | The `tailscale-state` volume. Node identity. |
| `/var/lib/docker` | The `docker-data` volume. The nested daemon's images and containers. |
| `/etc/docker/daemon.json` | The nested daemon's config, copied from `config/docker/daemon.json` each boot. Its own copy line, because the config sync targets `/home/dev`. |
| `/var/log/dockerd.log` | The nested daemon's output. Kept out of the container log, which `dockerd` would bury at info level. |

## Ports

| Port | Bound where | When |
|---|---|---|
| 22 | Tailnet address only, inside the container's network namespace | Always. Not changeable — Tailscale SSH assumes 22. |
| 6768 | `0.0.0.0` inside the container | Only on a `WITH_ORCA=true` build |
| whatever a project stack publishes | `0.0.0.0` inside the container | Only on a `WITH_DOCKER=true` build. Reachable at `http://<tailnet-name>:<port>` and, like 6768, from the Docker host. |

There is no `ports:` key in `docker-compose.yml`, so nothing is published to the
Docker host or the internet. The exception worth knowing: `orca serve` binds
`0.0.0.0` with no bind-address flag, so 6768 is reachable on the container's
bridge IP from the Docker host — do not attach other containers to devaloy's
network.

## Volumes

| Volume | Mounted at | Holds |
|---|---|---|
| `home` | `/home/dev` | Repos, toolchain, credentials, history, skills |
| `tailscale-state` | `/var/lib/tailscale` | Node identity |
| `docker-data` | `/var/lib/docker` | The nested daemon's images, containers and volumes. Only used on a `WITH_DOCKER=true` build, but always declared. |

`docker compose down` keeps all three. `docker compose down -v` destroys all
three. `docker-data` is pure cache and is the one safe to delete on purpose when
the disk fills.

_Verified against `main`@`d2e6886` plus the uncommitted browser-capture change on 2026-09-07._
