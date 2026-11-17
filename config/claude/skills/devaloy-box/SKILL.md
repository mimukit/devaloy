---
name: devaloy-box
description: >-
  How this devaloy box works: the Docker daemon, the mise toolchain, global npm installs, skills install, the headless browser driver, Claude usage limits, GitHub auth, and the permission mode. Use before you run docker, install or upgrade a tool, run npm i -g, install a skill, run a browser check, read Claude usage limits, or touch gh auth.
---

# devaloy-box

## What persists

`/home/dev` is a Docker named volume. Cloned repos, shell history, and tool credentials survive a redeploy. Everything outside `/home/dev` is thrown away on the next `docker compose up --build`, including anything you `sudo apt install`. A tool worth keeping belongs in the devaloy repo's `Dockerfile`, not in an ad hoc install on the box.

There is no backup job and no snapshot. A `docker compose down -v` erases the home volume. Git-tracked work is recoverable only if it has been pushed.

## Docker

This box may or may not have a Docker daemon. It depends on how the image was built. Check before you assume either way:

```sh
docker info >/dev/null 2>&1 && echo "daemon up"
```

If that prints nothing, the box was built without `WITH_DOCKER=true`. Say so. Do not try to install Docker or start a daemon; both need an image rebuild you cannot do from inside the container.

When it is there, it is a real daemon inside this container, not the host's. A bind mount resolves against this filesystem, and a published port lands on the tailnet. Rules:

- Use it for a project's own development stack: `docker compose up -d` in a repo you cloned.
- Never pass `--privileged`, and never grant `--cap-add SYS_ADMIN` or `--pid=host` to a nested container.
- Never bind mount a path from outside `/home/dev`. Mounting `/`, `/etc`, `/var/run/docker.sock` or the parent's own paths defeats the boundary.
- Never edit `/var/lib/docker` by hand. It is a named volume the daemon owns. Use `docker` commands, and `devaloy prune --apply` when the disk is full.

`docker` needs no `sudo`. The daemon log is `/var/log/dockerd.log`. Read it when a stack will not start.

## The toolchain

Node, pnpm, gh and turbo come from `mise` and resolve through shims in `~/.local/share/mise/shims`. To add or upgrade one, edit `bootstrap-toolchain.sh` in the devaloy repo and run `devaloy update`. Do not install a second copy with `apt` or a raw `curl | sh`.

After any `npm i -g`, run `devaloy update` so the new binary is visible to non-interactive sessions (`ssh devaloy '<cmd>'`, `scp`, `rsync`, git-over-ssh).

## Skills

Agent skills come from the `mimukit/skills` repo through the skills.sh CLI, not from this box's config. `skmi` installs or refreshes them all. `skup` only updates what is already installed, so a newly published skill needs `skmi`.

The exceptions live in the devaloy repo under `config/claude/skills/`: `devaloy-clean`, `devaloy-fleet`, `devaloy-box` and `codex-images`. `devaloy update --config-only` copies them into `~/.claude/skills/`. Use `devaloy-fleet` for any work on more than one devaloy box.

## Browser driver

`verifykit`, and the browser checks in `qakit` and `afkkit`, drive a headless Chromium through `playwright-cli`. The box has it only when built with `WITH_BROWSER=true`. Check before you assume either way:

```sh
command -v playwright-cli >/dev/null && ls ~/.cache/ms-playwright | grep -q '^chromium' && echo "driver present"
```

If that prints nothing, the box has no browser driver. Say so, and leave the page checks to the human.

## Claude usage limits

Read the Claude 5-hour and 7-day limits with `usage --json`. It reads local caches only and sends no request to Anthropic. The `fetchedAtMs` and `source` fields tell you how old the reading is.

Never run `usage --fetch`, `usage --curl` or `usage --force` unless the human asks for it in this session. `--fetch` is an automated Claude Code turn that spends tokens, and `--curl` sends a request that claims to be Claude Code. Both put the account at risk.

With `WITH_T3CODE_PROXY_CLAUDE_USAGE=true`, the Claude usage proxy serves the same numbers to T3 Code. Its log is `/var/log/devaloy-claude-usage-proxy.log`, and `devaloy doctor` shows it as the `claude usage` row.

## GitHub

If `GITHUB_TOKEN` is set in the environment, `gh` and `git push` over HTTPS are already authenticated. Do not run `gh auth login`. It refuses while that variable is set, which is expected.

## Permission mode

This box runs in `bypassPermissions` mode, set by `permissions.defaultMode` in `~/.claude/settings.json`. Every session on the box starts that way. The reason is `afkkit`: an unattended overnight run must not stop for a prompt, and an allowlist always leaves a gap. The container is disposable and has no other tenants.

The `deny` list in the same file still applies. Bypass mode removes the prompt, not the deny rules, and it does not relax the rules under "Deleting" in `CLAUDE.md`.
