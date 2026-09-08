# Size the container resource limits

devaloy ships with **every resource ceiling off**. A hardcoded number in
`docker-compose.yml` would bake in a host-size assumption, so all six knobs read
from `.env`. Five default to Docker's "unlimited"; `DEVALOY_CPU_SHARES` defaults
to the neutral weight `1024`. That is the right default for a
box on its own hardware and the wrong one the moment devaloy shares a host with
anything you care about.

Without a `mem_limit`, devaloy can grow until the **host** runs out and the
kernel picks a victim by `oom_score` — which on a box with neighbours is rarely
the process you would have chosen. With one, the cgroup OOM killer fires inside
devaloy only: it takes the largest process there, `tini` survives as PID 1, and
nothing else on the host notices.

This page covers the container half. The host half — earlyoom, swappiness, log
rotation, prune timer — is in [The host resource guard](host-resource-guard.md),
and the two are complementary rather than alternatives.

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

## Two full boxes on one host

Running a second devaloy is not running a smaller one. Both boxes get the same limits, and the way you fit them into a host that cannot hold two peaks at once is swap, not asymmetry.

The worked host: 11.4 GiB RAM, 6 vCPU, sharing with two WordPress stacks, a Traefik, a Beszel and Dokploy's own infra containers. Those neighbours together measure 311 MiB. The two boxes peak at 5-6 GiB each when several Claude Code sessions and a couple of dev servers are running.

Same `.env` values in both stacks:

```sh
DEVALOY_MEM_LIMIT=4500m
DEVALOY_MEMSWAP_LIMIT=10g
DEVALOY_MEM_RESERVATION=1500m
DEVALOY_CPUS=4
DEVALOY_CPU_SHARES=512
DEVALOY_PIDS_LIMIT=1024
```

The RAM caps total 9 GiB and leave 2.4 GiB for the host, dockerd and the neighbours. Each box may then take 5.5 GiB of swap on top of its 4.5 GiB of RAM, which is what carries the 5-6 GiB peak. `DEVALOY_CPUS=4` on a 6-core host is deliberate overcommit: one box can use most of the machine while the other is idle, and `cpu_shares` at 512 means the live sites win when all three want the CPU at once.

### Swap has to be real

The ceilings above promise 11 GiB of swap between them. A 3 GiB swap file cannot honour that, and the cgroup killer fires instead of the box going slow.

```sh
sudo swapoff -a
sudo fallocate -l 12G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Add it to `/etc/fstab` so it survives a reboot.

Then raise swappiness, because the guard script's default of `10` is tuned for the opposite goal:

```sh
sudo SWAPPINESS=60 scripts/host-resource-guard.sh --apply
```

The variable goes **after** `sudo`, not before it. Written the other way round it sets the variable for `sudo` itself, `sudo` then strips it from the environment it hands the script, and the script falls back to its `10` default with no warning. The confirmation prompt is where you catch this: it prints the value it is about to set, so read `set vm.swappiness=60` before answering `y`.

At `10` the kernel keeps cold agent pages in RAM until it is nearly out. At `60` it moves them to swap early, which is what you want when a 12 GiB swap file exists specifically to hold them. Idle sessions are mostly cold pages and swap well. The cost is real: a session you return to after an hour pages back in and feels slow for a few seconds.

### The reclaim scripts

Two boxes at these limits need the memory and the disk given back on a schedule, not when you notice. `devaloy-ram` and `devaloy-disk` (see [Reference](reference.md#commands-on-the-box)) do that, and both report before they act.

The Paseo daemon is the reclaim that matters. On the worked box it and its `@getpaseo/server` workers held 5519 MiB of the container's 6450 MiB, with two workers alone at 2025 MiB and 1148 MiB. Restarting it is cheap because `entrypoint.sh` supervises it and brings it back ten seconds later:

```sh
devaloy-ram              # report: what is holding the memory
devaloy-ram --apply      # restart Paseo, TERM orphaned language servers
```

Run it between turns. Every pane the daemon owns dies with it.

Neither script can run on a timer inside the box, because the image has no cron and no systemd, and a background loop would not survive a redeploy. Put the timer on the host next to the `docker-prune.timer` that `scripts/host-resource-guard.sh --apply` already installs, and have it call:

```sh
docker exec devaloy devaloy-ram --apply
docker exec devaloy-two devaloy-ram --apply
```

Disk is the ceiling nobody watches. Two home volumes and a 12 GiB swap file share one disk, and `devaloy-prune` only covers the nested Docker daemon:

```sh
devaloy-disk                      # dry run, always read this first
devaloy-disk --apply --docker     # node_modules, dead worktrees, Docker
devaloy-disk --apply --caches     # also the pnpm/npm/turbo caches
```

### Fix the kill order before you rely on the cap

`entrypoint.sh` sets the Paseo supervisor to `oom_score_adj -250`, and the daemon inherits it. Interactive shells raise themselves back to `0`.

So when the 4.5 GiB cap fires, the cgroup killer prefers a Claude Code session over the Paseo daemon, even though the daemon holds most of the memory. You lose the work and keep the leak. Either raise the supervisor to `0`, or restart Paseo on a schedule so the cap is never the thing that fires. The scheduled restart is the smaller change and it is what the timer above does.

## What happens when devaloy hits the ceiling

The container starts at `oom_score_adj: -500`, which keeps `tailscaled` off the
OOM killer's list — losing it severs the only route you would use to recover the
box. Every interactive shell raises itself back to `0` on startup, and the
optional Orca server, `dockerd`, and the Paseo supervisor sit at `-250`.

So the kill order inside devaloy is deliberate: a runaway build or agent session
dies first, then Orca, `dockerd`, and the Paseo supervisor, and `tailscaled`
last. **You stay connected while the
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
- [The host resource guard](host-resource-guard.md) — earlyoom and swappiness,
  the backstop for everything a cgroup limit cannot see.
- [Deploy with Dokploy](deploy-with-dokploy.md) — where these variables go when
  Dokploy owns the `.env`.

_Verified against `main`@`b6bc42b` on 2026-08-25._
