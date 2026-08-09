# Reading `docker stats`

`docker stats` is the first thing you run when the box feels wrong, and three of
its eight columns mean something other than what they look like. This page
explains each one, the traps, and what the numbers on *this* box normally look
like.

```sh
docker stats --no-stream
```

Without `--no-stream` it takes over the terminal and refreshes until you hit
`Ctrl-C`. With it, you get one snapshot and your prompt back — which is what you
want when piping, scripting, or pasting the output somewhere.

## Quick reference

| Column | Means | The trap |
|---|---|---|
| `CONTAINER ID` | First 12 chars of the container ID | Changes on every redeploy |
| `NAME` | Container name | Dokploy's are `<project>-<service>-<replica>` |
| `CPU %` | **100% = one full core** | Not percent of the machine |
| `MEM USAGE / LIMIT` | Current use / cgroup ceiling | `LIMIT` shows host RAM when unset |
| `MEM %` | Usage ÷ limit | Only means "% of host" while unlimited |
| `NET I/O` | Received / transmitted, cumulative | Resets on restart |
| `BLOCK I/O` | Read / written to disk, cumulative | Page-cache hits never appear |
| `PIDS` | Tasks in the cgroup | Counts **threads**, not just processes |

## CONTAINER ID

The first 12 hex characters of the container's full 64-character ID. Every
Docker command accepts this truncated form:

```sh
docker logs 25f6ab9485cf
```

It is assigned at creation. It survives `docker restart`, but **changes on every
redeploy** — Dokploy destroys and recreates the container rather than restarting
it. If you are keeping notes, key them on the name, not the ID.

## NAME

For containers with an explicit `container_name` in their compose file —
`devaloy`, `dokploy-traefik` — this is just that name.

Everything Dokploy generates follows Compose's
`<project>-<service>-<replica>` pattern:

```
wordpress-example-com-2yphrl - wordpress - 1
└────────────── project ─────────────────┘  └ service ┘  └┘ replica
```

The trailing random suffix (`2yphrl`) is Dokploy's, so two projects for the same
domain cannot collide. `wordpress` versus `db` is the service name inside that
project's compose file, and `-1` is the replica index — you will only ever see
`-2` if something is scaled out.

## CPU %

**This is not percent of the machine.** It is normalised so that **100% equals
one fully saturated core**. Docker derives it from two consecutive samples:

```
(container CPU time delta ÷ system CPU time delta) × online CPUs × 100
```

On a 2-vCPU host the ceiling across all containers is 200%; on 4 vCPUs it is
400%. A single container showing `150%` is using one and a half cores, which is
entirely normal and not an error.

Two consequences worth internalising:

- **A number under 100% never means the box is busy.** devaloy at `18.33%` is
  using under a fifth of one CPU, however many the VM has.
- **It is a sample, not an average.** Docker reads the counters roughly a second
  apart and reports the delta. Catching the instant a build starts gives a
  number that says nothing about the last minute. Watch it stream for a few
  seconds before drawing conclusions.

To know what the ceiling actually is:

```sh
nproc
```

## MEM USAGE / LIMIT

**Usage** is not plain RSS. Docker reports the cgroup's `memory.current` minus
`inactive_file` — roughly "anonymous memory plus page cache currently in use."
A container churning through files reads higher than the sum of its processes'
private memory, and that is correct rather than a bug.

It **excludes swap**. A container whose pages have been swapped out shows
*lower* here, not higher. On a box with swap enabled, a suspiciously small
number can mean memory pressure rather than the absence of it.

**LIMIT** is the cgroup's `memory.max`. When no limit is set there is nothing to
report, so Docker substitutes **total host RAM**. This is the single most useful
tell in the whole output:

```
MEM USAGE / LIMIT
979.3MiB / 3.73GiB
236.6MiB / 3.73GiB
18.68MiB / 3.73GiB
```

Six containers reading the same `3.73GiB` is not six coincidences — it means
**not one of them has a ceiling**, and any of them can take the host down. See
[vm-resource-limits.md](vm-resource-limits.md) for the fix. Once limits are set,
this column shows six different numbers.

## MEM %

Simply `MEM USAGE ÷ LIMIT × 100`:

```
979.3 MiB ÷ 3.73 GiB = 25.64%
```

**This column changes meaning the moment you set limits.** While `LIMIT` is host
RAM, `MEM %` happens to mean "percent of the VM," and adding the rows up gives a
real total. After per-container limits are applied it means "percent of *this
container's own allowance*," the rows no longer sum to anything, and a container
sitting at 80% of a small limit is fine rather than alarming.

Do not build a habit on the pre-limit reading.

## NET I/O

**Received / transmitted**, cumulative since the container started, summed over
every interface in its network namespace. It resets to zero on restart, so a
small number means either "quiet" or "recently redeployed" — check `docker ps`
uptime before concluding anything.

The direction is where the value is. From a loaded snapshot of this box:

| Container | NET I/O | Reading |
|---|---|---|
| `…example…db-1` | `211MB / 6.59GB` | Sent 6.59 GB |
| `…example…wordpress-1` | `6.76GB / 1.63GB` | Received 6.76 GB, sent 1.63 GB |

Those two rows are the same conversation from both ends: MySQL shipping query
results to PHP. The site served only 1.63 GB to the actual internet while
pulling 6.76 GB out of its database — a ~4:1 ratio that says the WordPress
install has no object cache and is re-running the same queries on every request.

`dokploy-traefik` at `1.23GB / 1.24GB` is near-symmetric, which is exactly what a
reverse proxy should look like: everything in comes back out.

## BLOCK I/O

**Read / written** to block devices, cumulative since start, from the cgroup's
`io.stat`.

The caveat that matters: this counts I/O that **reached the block layer**. A
file read served from the kernel's page cache never appears. So a low read
number is ambiguous — it can mean "barely touches disk" or "reads the same hot
files constantly and always hits cache." Writes are the more honest half, since
they eventually have to land.

Also invisible here: `tmpfs` (never touches a block device) and anything written
by a *sibling* container to a shared volume, which is billed to whoever issued
the write.

devaloy's `13.3GB / 7.38GB` dwarfs everything else on this box — mise
toolchains, git operations, `node_modules`, and agent scratch files.

## PIDS

The cgroup's `pids.current`. It counts **tasks, which includes threads** — a
single multi-threaded Node process contributes a dozen on its own. devaloy's
`117` is emphatically not 117 programs.

This is the column a runaway `fork` moves first, and the reason `pids_limit` is
worth setting even though it never binds in normal operation.

## Baselines for this box

Useful for telling "busy" from "wrong." Both taken from the same VM, 3.73 GiB
RAM, 4 GiB swap:

**Idle** — nothing running in devaloy:

| Container | CPU % | MEM | PIDS |
|---|---|---|---|
| `devaloy` | 0.11% | 437.5 MiB | 92 |
| `…example…wordpress-1` | 0.01% | 167.3 MiB | 11 |
| `…architects…wordpress-1` | 0.01% | 113.9 MiB | 11 |
| `…architects…db-1` | 0.01% | 23.9 MiB | 15 |
| `dokploy-traefik` | 0.00% | 25.9 MiB | 9 |
| `…example…db-1` | 0.01% | 17.7 MiB | 15 |
| **total** | | **786 MiB** (21%) | 163 |

**Under load** — several Claude Code sessions in devaloy, sites taking traffic:

| Container | CPU % | MEM | PIDS |
|---|---|---|---|
| `devaloy` | 18.33% | 979.3 MiB | 117 |
| `…example…wordpress-1` | 0.01% | 236.6 MiB | 11 |
| `…architects…wordpress-1` | 0.00% | 120.8 MiB | 11 |
| `dokploy-traefik` | 0.00% | 27.2 MiB | 9 |
| `…example…db-1` | 0.02% | 18.7 MiB | 15 |
| `…architects…db-1` | 0.01% | 16.5 MiB | 15 |
| **total** | | **1399 MiB** (37%) | 178 |

The shape of the delta is the useful part: **devaloy more than doubles while
everything else barely moves.** The WordPress containers grow modestly under
traffic (php-fpm forking workers) and the databases actually shrink. On this box,
memory pressure means devaloy, essentially always.

## Common misreadings

- **"CPU is at 18%, we have loads of headroom."** 18% of *one core*. On a 2-vCPU
  box that is 9% of the machine — but a single container at 190% would mean you
  are nearly out, while still looking like a small number next to 3.73GiB.
- **"Every container is limited to 3.73GiB."** None of them are limited. That is
  the host's RAM being shown because there is no limit to report.
- **"BLOCK I/O is low, so it is not disk-bound."** Cached reads never appear
  here. Check `iostat` or the container's actual behaviour.
- **"NET I/O is huge, we are burning bandwidth."** Most of it is usually
  container-to-container on a private bridge, which costs nothing at the
  provider. Compare the two directions to work out which is which.
- **"MEM USAGE is low, so there is no pressure."** Swapped-out pages are not
  counted. Cross-check with `free -h`.

## What `docker stats` cannot tell you

| Question | Use instead |
|---|---|
| Disk **space** (not I/O) | `docker system df` and `df -h /` |
| Which process inside a container | `docker exec <name> ps aux` |
| Swap usage | `free -h`, `swapon --show` |
| History / trends | It is instantaneous only — sample into a file |
| Whether a container is restarting | `docker ps -a` (check `Status`) |

## Useful invocations

One snapshot, only the columns that matter:

```sh
docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}'
```

Just one project:

```sh
docker stats $(docker ps --format '{{.Names}}' | grep architects)
```

Verify limits actually applied after a redeploy:

```sh
docker inspect --format \
  '{{.Name}} mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}} cpus={{.HostConfig.NanoCpus}} pids={{.HostConfig.PidsLimit}}' \
  $(docker ps -q)
```

Sample every 30s into a file, to catch a spike you are not awake for:

```sh
while :; do
  date -Is >> /tmp/stats.log
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' >> /tmp/stats.log
  sleep 30
done
```

Available `--format` placeholders: `.Container`, `.ID`, `.Name`, `.CPUPerc`,
`.MemUsage`, `.MemPerc`, `.NetIO`, `.BlockIO`, `.PIDs`.

## Where the numbers come from

Every column is read straight out of the container's cgroup, so you can verify
any of them by hand on a cgroup v2 host:

```sh
stat -fc %T /sys/fs/cgroup/          # cgroup2fs = v2
```

| Column | Source |
|---|---|
| `CPU %` | `cpu.stat` → `usage_usec` |
| `MEM USAGE` | `memory.current` − `inactive_file` |
| `LIMIT` | `memory.max` (`max` = unset, so host RAM is shown) |
| `BLOCK I/O` | `io.stat` → `rbytes` / `wbytes` |
| `PIDS` | `pids.current` |
| `NET I/O` | Interface counters in the container's netns |

## See also

- [vm-resource-limits.md](vm-resource-limits.md) — setting the limits that make
  the `LIMIT` column meaningful, and keeping the VM up under pressure.
- [deploy-with-dokploy.md](deploy-with-dokploy.md) — where the Dokploy container
  names come from.
