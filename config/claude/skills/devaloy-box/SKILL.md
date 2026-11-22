---
name: devaloy-box
description: >-
  Check devaloy persistence, Docker, tool updates, skill installation, headless Chromium, GitHub authentication, or Claude usage and permissions.
---

# devaloy-box

## What persists

Check `RUNTIME` in `/opt/devaloy/build-flags`. Older container builds omit that line. The runtime determines what survives:

- Container. The `/home/dev` volume survives a rebuild. A rebuild replaces the container filesystem. `docker compose down -v` deletes the home volume.
- Native. The home directory is on the VM's filesystem. A devaloy update keeps it.
- Upstash. Only data under `/workspace` survives a reset. This includes the persistent home at `/workspace/home`.

Keep system dependencies in devaloy's shared installer or package lists so a fresh install includes them.

## Docker

Run `docker info` to check whether the current user can reach the daemon. If it fails, report the error. Check the runtime and `WITH_DOCKER` in `/opt/devaloy/build-flags` to find the cause.

- Container. If the build flag is false, Docker needs an image rebuild. If Docker is present, the daemon runs inside devaloy. Check `/var/log/dockerd.log` if it fails to start.
- Native. Docker runs as a systemd service when the installer enables it. Check `systemctl status docker` and `journalctl -u docker`.
- Upstash. The installer disables Docker. Report that the project stack needs a runtime with Docker.

With a working daemon, use `docker compose up -d` from the project repository. On a full Docker disk, use `devaloy prune` to inspect what it can remove.

## The toolchain

Node, pnpm, gh and turbo come from `mise` and resolve through shims in `~/.local/share/mise/shims`. Change managed tool versions in `config/mise/` or `bootstrap-toolchain.sh`, then run `devaloy update`. Use the managed toolchain for changes that must persist.

After any `npm i -g`, run `devaloy update` so the new binary is visible to non-interactive sessions (`ssh devaloy '<cmd>'`, `scp`, `rsync`, git-over-ssh).

## Skills

Agent skills come from the `mimukit/skills` repo through the skills.sh CLI, not from this box's config. `skmi` installs or refreshes them all. `skup` only updates what is already installed, so a newly published skill needs `skmi`.

The devaloy repo provides local skills in `config/claude/skills/`. The boot and `devaloy update --config-only` copy them to `~/.claude/skills/`. They also copy this skill to `~/.codex/skills/`. Use `devaloy-fleet` for work on more than one devaloy box.

## Browser driver

`verifykit`, `qakit` and `afkkit` use `playwright-cli` and headless Chromium. Check for both before you start:

```sh
command -v playwright-cli >/dev/null && ls ~/.cache/ms-playwright | grep -q '^chromium' && echo "driver present"
```

If the check prints nothing, report which component is missing. Use the runtime's install guide to check how to enable `WITH_BROWSER`.

## Claude usage limits

Read the Claude 5-hour and 7-day limits with `usage --json`. It reads local caches only and sends no request to Anthropic. The `fetchedAtMs` and `source` fields tell you how old the reading is.

Never run `usage --fetch`, `usage --curl` or `usage --force` unless the human asks for it in this session. `--fetch` is an automated Claude Code turn that spends tokens, and `--curl` sends a request that claims to be Claude Code. Both put the account at risk.

With `WITH_T3CODE_PROXY_CLAUDE_USAGE=true`, the Claude usage proxy serves the same numbers to T3 Code. Its log is `/var/log/devaloy-claude-usage-proxy.log`, and `devaloy doctor` shows it as the `claude usage` row.

## GitHub

If `GITHUB_TOKEN` is set in the environment, `gh` and `git push` over HTTPS are already authenticated. Do not run `gh auth login`. It refuses while that variable is set, which is expected.

## Permission mode

The managed Claude settings set `permissions.defaultMode` to `bypassPermissions` for unattended runs. Check the active session before you assume that mode. The deny list and the global delete rules still apply. Codex uses its own sandbox and approval settings.
