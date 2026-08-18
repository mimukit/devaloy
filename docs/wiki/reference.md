# Reference

Declared surface only: the variables, commands, flags and managed paths this
repo defines in one place. For what any of it is *for*, see
[Architecture](architecture.md).

## Environment variables

All are set in `.env` beside `docker-compose.yml`, and every one is optional
except `TS_AUTHKEY` on a first boot.

### Tailscale

| Variable | Default | Effect |
|---|---|---|
| `TS_AUTHKEY` | empty | Auth key for joining the tailnet. Must be **reusable, non-expiring and untagged**. Optional on a redeploy — the node identity is already in the `tailscale-state` volume. |
| `TS_HOSTNAME` | `devaloy` | Node name on the tailnet, and the name given to the signing key registered on GitHub. |
| `TS_ACCEPT_DNS` | `false` | `true` passes `--accept-dns=true`. Letting Tailscale rewrite `/etc/resolv.conf` inside a container clobbers Docker's resolver — turn it on only if you need MagicDNS resolution *from* the box. |

### Credentials

| Variable | Default | Effect |
|---|---|---|
| `GITHUB_TOKEN` | empty | Authenticates `gh` and `git push` over HTTPS from first boot. Written to `~/.devaloy_secrets` **and** stored via `gh auth login --with-token`. |
| `CLAUDE_CODE_OAUTH_TOKEN` | empty | Authenticates Claude Code with no interactive `/login`. Generate with `claude setup-token` on a machine that has a browser. |
| `GIT_AUTHOR_NAME` | empty | `user.name`. Falls back to the `GITHUB_TOKEN` account's name. |
| `GIT_AUTHOR_EMAIL` | empty | `user.email`. Falls back to that account's `ID+login@users.noreply.github.com` address. |
| `GIT_SIGNING_SSH_KEY` | empty | Base64 of a **passphrase-less OpenSSH private key**. Enables SSH commit and tag signing. |

Clearing any of these and redeploying **revokes** it: `~/.devaloy_secrets`,
`~/.config/gh/hosts.yml`, `~/.config/agent-push.env` and the signing key are all
deleted and rebuilt from scratch on every boot.

`GIT_SIGNING_SSH_KEY` wants the **private** half. A correct value runs to several
hundred characters and decodes to a `BEGIN OPENSSH PRIVATE KEY` block; anything
near a hundred characters is the public half and is rejected at boot. Literal PEM
is also accepted, for the case where the value arrives through some channel that
can carry newlines.

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
| `WITH_PASEO` | `false` | Installs the `paseo` CLI through mise and starts its daemon on `<tailnet-ip>:6767` with `--no-relay`. A **runtime** variable, unlike `WITH_ORCA` — `docker compose up -d` picks up a change with no `--build`. Setting it back to `false` stops the daemon; it uninstalls nothing and does not touch `~/.paseo`. |
| `WITH_PASEO_WEB_UI` | `false` | Adds `--web-ui` and `--hostnames "${TS_HOSTNAME},.ts.net"`, serving a browser client from the daemon's origin. Static files load without auth. |
| `PASEO_PASSWORD` | empty | Optional, and **daemon-wide** rather than web-UI only: setting it makes the phone's direct connection ask for it too. Written to `~/.devaloy_secrets` (0600). Empty with `WITH_PASEO_WEB_UI=true` logs a warning and serves anyway. |

Flipping `WITH_PASEO` re-runs the toolchain bootstrap, because the revision
marker records the key alongside the revision (`5` vs `5+paseo`). The boot path
installs and never upgrades, so nothing already on the volume moves.

### Toolchain pins

| Variable | Default | Effect |
|---|---|---|
| `MISE_NODE_VERSION` | `24` | Node **major**, not mise's floating `lts` alias — that alias rolls across majors. |
| `MISE_HERDR_VERSION` | `latest` | Pin herdr. |
| `MISE_PASEO_VERSION` | `latest` | Pin `@getpaseo/cli`. Only read when `WITH_PASEO=true`. |

Everything else in the toolchain (`pnpm`, `gh`, `turbo`, `lazygit`, `claude`,
`codex`, `skills`) tracks `latest` and is pinned by editing
`bootstrap-toolchain.sh`, not by a variable.

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

## Build arguments

| Argument | Default | Effect |
|---|---|---|
| `WITH_ORCA` | `false` | Builds in the `orca serve` runtime. Takes the image from 683 MB to 1.6 GB on arm64. |

`WITH_ORCA` is read from `.env` like the variables above, but it is a **build
argument** — `docker compose up -d` alone will not pick up a change to it. You
need `docker compose up -d --build`.

`WITH_PASEO` is the one to keep separate in your head. It looks like a sibling
and is not: it is an environment variable listed above, because Paseo installs
into the home volume rather than the image. It needs no `--build`.

Two more are pinned in the `Dockerfile` itself rather than exposed through
compose: `ORCA_VERSION` (`1.4.164`) and `ZSH_COMPLETIONS_VERSION` (`0.36.0`).
Changing either means editing the file and rebuilding.

## Commands on the box

Run as the `dev` user unless noted.

| Command | Effect |
|---|---|
| `devaloy-update` | Re-runs the bootstrap with `--force`, then refreshes the `/usr/local/bin` mirror. Refuses to run as root. |
| `bootstrap-toolchain.sh` | Installs the toolchain, but **skips itself** if the home volume already records the current `TOOLSET_REVISION`. |
| `bootstrap-toolchain.sh --force` | Installs regardless, and additionally runs `mise upgrade` to re-resolve everything tracking `latest`. |
| `link-shims` | Mirrors mise's shims into `/usr/local/bin`. **Needs root.** Reads `DEV_HOME` (default `/home/dev`). Never clobbers a real file, only symlinks. |

Any argument to `bootstrap-toolchain.sh` other than `--force` exits `2` without
installing anything.

### Aliases

devaloy-specific, from `config/zsh/zshrc`. The file also carries the usual
`ll`/`gs`/`gd` shorthands, which are not listed here.

| Alias | Expands to |
|---|---|
| `update` | `devaloy-update` |
| `skmi` | `skills add mimukit/skills --global --skill '*' -a claude-code -a codex -y` |
| `skup` | `skills update --global -y` |
| `clc` | `claude --model "claude-opus-5[1m]"` |
| `clcy` | `claude --allow-dangerously-skip-permissions` |
| `cx` | `codex` |
| `h` | `herdr` |
| `gg` | `lazygit` |
| `reload` | `exec zsh` |
| `zsrc` | `. "$HOME/.zshrc"` |

`skmi` is what picks up a **newly authored** skill. `skup` only refreshes what is
already in the lockfile, so it will never notice one that was not installed
before.

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
| `-h`, `--help` | Usage |

| Variable | Default |
|---|---|
| `SWAPPINESS` | `10` |
| `LOG_MAX_SIZE` | `10m` |
| `LOG_MAX_FILE` | `3` |
| `PRUNE_KEEP_HOURS` | `168` |
| `EARLYOOM_AVOID` | `^(sshd\|dockerd\|containerd\|tailscaled\|traefik\|mariadbd\|mysqld)$` |
| `EARLYOOM_PREFER` | `^(apache2\|node\|npm\|pnpm\|turbo\|esbuild)$` |

## Managed files

Written or overwritten by `entrypoint.sh` on **every boot**. Editing any of these
on the box is pointless — the change is gone at the next redeploy.

| Path | Mode | Contents |
|---|---|---|
| `~/.devaloy_env` | default | `PATH`, the mise release-age exclusion, sources `~/.devaloy_secrets`, resets `oom_score_adj` |
| `~/.devaloy_secrets` | **600** | `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` — only written when set |
| `~/.config/agent-push.env` | **600** | `PUSH_NTFY_*` — only written when `NTFY_TOPIC` is set |
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
| `~/.local/share/mise/.devaloy-bootstrapped` | The `TOOLSET_REVISION` marker. Written last, and only on success. |
| `/usr/local/bin` | The `link-shims` mirror. Outside the volume, so it is rebuilt each boot. |
| `/opt/devaloy/config` | The image's copy of `config/`, the source for the sync |
| `/var/lib/tailscale` | The `tailscale-state` volume. Node identity. |

## Ports

| Port | Bound where | When |
|---|---|---|
| 22 | Tailnet address only, inside the container's network namespace | Always. Not changeable — Tailscale SSH assumes 22. |
| 6768 | `0.0.0.0` inside the container | Only on a `WITH_ORCA=true` build |

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

`docker compose down` keeps both. `docker compose down -v` destroys both.

_Verified against `main`@`3c56b41` on 2026-08-09._
