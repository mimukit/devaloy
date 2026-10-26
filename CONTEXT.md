# devaloy

devaloy is a self-contained dev box: one Docker Compose container that you reach only over Tailscale SSH. This file defines the words the repo, the wiki and the agent instructions use for its parts.

## Overview

### What it is
A portable Docker Compose dev box, one `ubuntu:24.04` container that runs `tailscaled` with SSH. Its home volume keeps the toolchain, agent credentials and cloned repos across redeploys.

### Who it is for
One developer who runs AI coding agents and works from a phone or a laptop. Other people can fork the repo and run their own box.

### The problem it solves
Development stays on one remote machine, so a session continues from any device on any network. No public IP, published port or SSH key is necessary.

### Core capabilities
- Tailscale SSH access with no sshd and no keys, authorized by the tailnet policy file
- A home volume that keeps repos, history, credentials and the toolchain across redeploys
- A declarative toolchain from mise, installed on first boot and changed only by a toolset edit or `devaloy update`
- Shell and agent config shipped from `config/` and synced over the box on each boot
- Claude Code and Codex with shared agent skills from `mimukit/skills`
- One `devaloy` command for status, health, reclaims and toolchain updates
- Optional build flags for a nested Docker daemon, headless browser capture, Paseo and T3 Code

### Non-goals
- No browser IDE, no mosh, no public HTTPS domain, no SSH keys or fallback sshd
- No access to the host's Docker socket
- No backup job: a push to a remote is the only backup

## The box and where it runs

### Box
One running devaloy stack: the container plus its `home`, `tailscale-state` and `docker-data` volumes, named by `DEVALOY_NAME`.
_Avoid: VM, server, VPS (for the box itself), devcontainer_

### Host
The Docker host machine that runs the box. It is outside the box and is not reachable from inside it.
_Avoid: server (when ambiguous), VPS (as a synonym for the box)_

### Host resource guard
The host-side setup from `scripts/host-resource-guard.sh`: earlyoom, swappiness, log rotation and a prune timer. It protects the host from what the box's container limits cannot reach.
_Avoid: OOM guard, host tuning_

### Home volume
The `home` named volume mounted at `/home/dev`. It is the only box state that survives `docker compose up --build`, and `down -v` erases it.
_Avoid: persistent volume, data volume_

### Backup contract
The rule that the box has no backup and that a push to a remote is the only copy of work that counts.
_Avoid: backup policy, snapshot_

### Break-glass path
The way into an unreachable box through `docker compose exec` on the host, because the box has no sshd fallback.
_Avoid: fallback SSH, rescue mode_

## Tools and config

### Toolchain
The tools that mise installs into the home volume: node, pnpm, gh, turbo, the agent CLIs and the rest of `config/mise/config.toml`.
_Avoid: toolset (for the installed tools), dev tools_

### Toolset
The declared tool list: `config/mise/config.toml` with its pins and the optional fragments that build flags turn on, hashed as one value.
_Avoid: toolchain (for the declared list), TOOLSET_REVISION_

### Toolset gate
The boot check that runs the toolchain bootstrap only when the toolset hash differs from the marker in the home volume.
_Avoid: revision bump, install marker_

### Build flag
A `WITH_*` key in `.env` (`WITH_DOCKER`, `WITH_BROWSER`, `WITH_PASEO`, `WITH_T3CODE`) that turns on an optional part of the box.
_Avoid: feature flag, WITH_* key, option_

### Config sync
The boot step that copies each file under `config/` over its counterpart in the home volume. The repo copy wins, and files the repo does not ship stay as they are.
_Avoid: dotfiles install, config deploy_

### Reclaim
A `devaloy` verb that frees one resource: `disk` for the home volume, `ram` for memory, `prune` for the nested daemon. It reports what it finds and acts only on that list on `--apply`.
_Avoid: cleanup, GC_

## Project stacks

### Nested daemon
The Docker daemon that runs inside the box when it is built with `WITH_DOCKER=true`. It is never the host's daemon.
_Avoid: host Docker, Docker-in-Docker (as the name), DinD_

### Project stack
A cloned repo's own Docker Compose stack, run on the nested daemon. Its bind mounts resolve inside the box, and its published ports land on the tailnet.
_Avoid: dev stack, app stack_
