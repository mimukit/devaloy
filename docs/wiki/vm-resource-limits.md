# Size the container resource limits

devaloy ships with **every resource ceiling off**. A hardcoded number in
`docker-compose.yml` would bake in a host-size assumption, so all six knobs read
from `.env` and default to Docker's "unlimited". That is the right default for a
box on its own hardware and the wrong one the moment devaloy shares a host with
anything you care about.

Without a `mem_limit`, devaloy can grow until the **host** runs out and the
kernel picks a victim by `oom_score` — which on a box with neighbours is rarely
the process you would have chosen. With one, the cgroup OOM killer fires inside
devaloy only: it takes the largest process there, `tini` survives as PID 1, and
nothing else on the host notices.

This page covers the container half. The host half — earlyoom, swappiness, log
rotation, prune timer — is in [Harden the Docker host](harden-the-host.md), and
the two are complementary rather than alternatives.

## The six variables

All are set in `.env` and substituted into `docker-compose.yml`.

| Variable | Compose key | Default | Meaning |
|---|---|---|---|
| `DEVALOY_MEM_LIMIT` | `mem_limit` | `0` (unlimited) | Hard RAM ceiling. The cgroup OOM killer fires at this number. |
| `DEVALOY_MEMSWAP_LIMIT` | `memswap_limit` | `0` (2× `mem_limit`) | **Combined RAM + swap** ceiling, not swap on its own. |
| `DEVALOY_MEM_RESERVATION` | `mem_reservation` | `0` (none) | Soft floor. Under host pressure the kernel tries to leave devaloy this much. |
| `DEVALOY_CPUS` | `cpus` | `0` (unlimited) | Decimal core count, e.g. `1.5`. A hard cap, always enforced. |
| `DEVALOY_CPU_SHARES` | `cpu_shares` | `1024` | Relative weight. **Only bites under contention.** |
| `DEVALOY_PIDS_LIMIT` | `pids_limit` | `-1` (unlimited) | Maximum processes and threads. |

Two of these mislead if you read them quickly:

- **`DEVALOY_MEMSWAP_LIMIT` is the total, not the swap allowance.** It must be
  `>=` `DEVALOY_MEM_LIMIT`, and the *difference* between the two is how much
  swap devaloy may use. Setting it equal to `DEVALOY_MEM_LIMIT` disables swap
  for the container entirely. Leaving it at `0` lets Docker default it to twice
  `DEVALOY_MEM_LIMIT`.
- **`DEVALOY_CPU_SHARES` is not a limit.** At `1024` — the Docker default —
  devaloy competes evenly with every other container. Below `1024` the
  neighbours win when both want CPU at once, which is the right call when the
  neighbours are someone's live site and this is a dev box. It does nothing at
  all on an idle host.

## Sizing them

Measure first. Set second.

### 1. Read the current numbers

```sh
docker stats --no-stream
```

If every container reports the same `LIMIT`, that number is total host RAM and
**none of them has a ceiling**. [Reading `docker stats`](reading-docker-stats.md)
covers what each column means and why that one is the most useful tell in the
output.

Take a reading while devaloy is idle and another while it is doing what you
actually bought it for — a couple of agent sessions and a build. The gap between
those two is what you are sizing for.

### 2. Set the memory ceiling above the busy reading

Give devaloy roughly **twice its observed peak**. Too tight and the cgroup OOM
killer takes an agent session mid-turn; too loose and the limit never engages.

The measured numbers on the reference box — 3.73 GiB RAM, 4 GiB swap, sharing
the host with two WordPress stacks and a Traefik — are in
[Baselines for this box](reading-docker-stats.md#baselines-for-this-box):
devaloy sits at **437 MiB idle** and **979 MiB with several Claude Code sessions
running**, against a host total of 1399 MiB under the same load.

That box wants roughly:

```sh
# in .env
DEVALOY_MEM_LIMIT=2g
DEVALOY_MEMSWAP_LIMIT=4g
DEVALOY_MEM_RESERVATION=512m
DEVALOY_CPUS=1.5
DEVALOY_CPU_SHARES=512
DEVALOY_PIDS_LIMIT=512
```

Read those as a worked example from those measurements, not as defaults. `2g` is
about double the 979 MiB peak; `512m` is a little above the idle reading; `512`
PIDs is comfortably above the 117 observed under load. `DEVALOY_CPUS=1.5`
assumes a 2-vCPU host — check yours with `nproc`, and scale it so devaloy can
still saturate most of the machine when nothing else wants it.

### 3. Be generous with swap

`DEVALOY_MEMSWAP_LIMIT=4g` against a `2g` RAM limit gives devaloy 2 GiB of swap.
Idle agent sessions are mostly cold pages and swap well, so a generous allowance
here buys you sessions that go **slow** rather than sessions that **die**. This
is the opposite of the advice you would give a latency-sensitive service.

### 4. Leave CPU alone unless the host is shared

`DEVALOY_CPUS` is a hard cap and will throttle a build even on a completely idle
host. On a box devaloy has to itself, leave it at `0` and set only
`DEVALOY_CPU_SHARES`, which costs nothing until there is contention.

### 5. Apply

```sh
docker compose up -d
```

No `--build` needed — these are runtime settings, not build arguments. (Contrast
`WITH_ORCA`, which *is* a build argument and does need `--build`.)

### 6. Confirm the limit engaged

```sh
docker stats --no-stream
```

`LIMIT` should now show your number for devaloy rather than host RAM. From the
host, `scripts/host-resource-guard.sh --check` reports the same thing across
every container and writes nothing:

```sh
scripts/host-resource-guard.sh --check
```

## What happens when devaloy hits the ceiling

The container starts at `oom_score_adj: -500`, which keeps `tailscaled` off the
OOM killer's list — losing it severs the only route you would use to recover the
box. Every interactive shell raises itself back to `0` on startup, and the
optional Orca server sits at `-250`.

So the kill order inside devaloy is deliberate: a runaway build or agent session
dies first, then Orca, and `tailscaled` last. **You stay connected while the
thing that caused the problem is the thing that dies.** That ordering is why a
`mem_limit` is safe to set aggressively.

## Cgroup version matters

```sh
stat -fc %T /sys/fs/cgroup/
```

`cgroup2fs` is what you want: `memswap_limit` behaves as described above, and
`mem_swappiness` does nothing. On cgroup v1 per-container swap behaves
differently. `scripts/host-resource-guard.sh --check` reports which one the host
is on.

## See also

- [Reading `docker stats`](reading-docker-stats.md) — the measurements this page
  asks you to take.
- [Harden the Docker host](harden-the-host.md) — earlyoom and swappiness, the
  backstop for everything a cgroup limit cannot see.
- [Deploy with Dokploy](deploy-with-dokploy.md) — where these variables go when
  Dokploy owns the `.env`.

_Verified against `main`@`3c56b41` on 2026-08-09._
