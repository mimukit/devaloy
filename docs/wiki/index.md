# devaloy documentation

A Docker Compose dev box you SSH into over Tailscale and pick up a coding
session from any device. These pages cover running it, changing it, and fixing
it when it stops answering.

## Start here

- [Getting started](getting-started.md) — from a clone to a shell on the box.
- [Architecture](architecture.md) — what runs where, what persists, and why it
  is one container rather than two.
- [Reference](reference.md) — every `.env` variable, every command, and every
  file the entrypoint manages.

## Tasks

- [Deploy with Dokploy](deploy-with-dokploy.md) — running the stack as a Dokploy
  Compose service instead of by hand.
- [Size the container resource limits](vm-resource-limits.md) — the six
  `DEVALOY_*` ceilings, and what to set them to.
- [Harden the Docker host](harden-the-host.md) — the two `scripts/` helpers that
  run on the host, not on devaloy.
- [Turn on phone push notifications](push-notifications.md) — one ntfy push per
  agent session when it blocks or finishes.
- [Pair the Orca apps](pair-the-orca-apps.md) — the optional `WITH_ORCA=true`
  runtime, for the desktop and mobile clients.

## When something is wrong

- [Recover a box you cannot reach](recover-an-unreachable-box.md) — the
  break-glass paths, all of which start on the Docker host.
- [Reading `docker stats`](reading-docker-stats.md) — what each column actually
  means, and the baselines for this box.

## Elsewhere in the repo

The [README](../../README.md) is the long-form setup guide: it covers every
optional step — the GitHub token, the Claude Code token, signed commits, the
Orca build — in more detail than [Getting started](getting-started.md), which
walks only the required path.

Agent instructions live in `config/claude/CLAUDE.md` and `config/codex/AGENTS.md`
and are written for the agents running on the box, not for readers.

_Verified against `main`@`3c56b41` on 2026-08-09._
