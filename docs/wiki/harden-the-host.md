# Harden the Docker host

Two scripts in `scripts/` do things a compose file cannot reach, because they
configure the **host**, not devaloy. Both are optional, both are aimed at a
cloud VPS, and neither is needed on a trusted machine at home.

Run both **on the Docker host**, as a user with `sudo`. Neither works from
inside devaloy — the container has no Docker client and no `ufw`.

| Script | What it protects | Safe to run blind? |
|---|---|---|
| `scripts/host-firewall-lockdown.sh` | The host's own management surface | Yes — two anti-lockout guards |
| `scripts/host-resource-guard.sh` | The host against a container eating it | Yes — reports only until `--apply` |

Neither protects devaloy itself. devaloy publishes no ports and has no `ports:`
key at all, so there is nothing on it to firewall.

## Lock down the host firewall

Denies all incoming traffic except on the `tailscale0` interface, using `ufw`.

```sh
sudo scripts/host-firewall-lockdown.sh
```

It refuses to run unless two things hold, and both refusals are the script doing
its job:

1. **Tailscale is up on the host** and the interface exists. Without a working
   tailnet there would be no route left after the rules apply.
2. **Your current SSH session came from a tailnet address** (`100.64.0.0/10`).
   Enabling the firewall from a session on the public IP would cut you off
   mid-command. Reconnect over Tailscale and re-run.

Override the second guard only if you are certain you have another way in:

```sh
sudo ALLOW_NON_TAILNET=1 scripts/host-firewall-lockdown.sh
```

If your tailnet interface is not called `tailscale0`, set `TS_IFACE`. Verify
afterwards:

```sh
sudo ufw status verbose
```

**No ports 80 or 443 are opened.** If the host also serves websites, this script
is not for you as written — it will take them offline.

## Guard the host's resources

Covers the four things per-container limits cannot: a process that kills the box
before you can log in, a kernel that swaps too eagerly, container logs that fill
the disk, and a build cache that does the same.

```sh
scripts/host-resource-guard.sh --check
```

`--check` is the default and **writes nothing**, so start there. It reports:

- RAM, swap and vCPU count, and whether swap exists at all
- cgroup version (`cgroup2fs` is what you want)
- root filesystem usage, flagged at 70% and again at 85%
- whether `earlyoom` is installed and running
- `vm.swappiness`
- whether Docker log rotation is configured
- whether a weekly prune timer is enabled
- **every running container's memory limit**, naming the ones that have none
- `docker system df`

That container list is the useful part, and it is the same signal the
[`docker stats` page](reading-docker-stats.md) teaches you to read. Fix those in
each stack's own compose file — for devaloy, see
[Size the container resource limits](vm-resource-limits.md). This script will
not do it for you, deliberately.

### Apply it

```sh
sudo scripts/host-resource-guard.sh --apply
```

It prompts before doing anything; `--yes` skips the prompt. It then:

- installs and starts **earlyoom** with `-m 8 -s 10 -r 3600`, so it acts when
  available memory drops below 8% or free swap below 10% — while the box is
  still responsive, which the kernel's own OOM killer is not
- sets `vm.swappiness = 10` and `vm.vfs_cache_pressure = 50` in
  `/etc/sysctl.d/99-devaloy-resources.conf`
- **merges** `log-driver` and `log-opts` into `/etc/docker/daemon.json`, keeping
  a timestamped backup beside it — a merge because Dokploy and others put their
  own keys in that file
- installs `docker-prune.service` and a `docker-prune.timer` firing Sunday 04:00

Two things it will not do:

- **It does not prune volumes.** The prune commands carry no `--volumes` flag,
  because named volumes hold live site data — and devaloy's own `/home/dev`.
- **It does not restart dockerd** unless you pass `--restart-docker`. Log
  rotation only reaches containers created after a restart, and a restart
  **bounces every container on the host**. Do it in a maintenance window.

### earlyoom's kill list

The defaults in the script encode which processes are cheap to lose:

- **Never killed** (`EARLYOOM_AVOID`): `sshd`, `dockerd`, `containerd`,
  `tailscaled`, `traefik`, `mariadbd`, `mysqld` — killing any of these costs you
  the box or the data.
- **Killed first** (`EARLYOOM_PREFER`): `apache2`, `node`, `npm`, `pnpm`,
  `turbo`, `esbuild` — an agent session or a build, both of which come back on
  their own.

Override either with an environment variable if your host runs something else
that must survive. The full list of overrides — `SWAPPINESS`, `LOG_MAX_SIZE`,
`LOG_MAX_FILE`, `PRUNE_KEEP_HOURS`, `EARLYOOM_AVOID`, `EARLYOOM_PREFER` — is in
the script's own `--help`.

### Confirm

```sh
scripts/host-resource-guard.sh --check
```

Everything it flagged with `✗` should now be `✓`, except container ceilings —
those are set per stack, not here.

## Do not run either of these under Dokploy without reading first

The Dokploy page has a whole section on why the firewall script will take a
Dokploy host offline: [Do not run the host firewall
script](deploy-with-dokploy.md#8-do-not-run-the-host-firewall-script).
`host-resource-guard.sh` is safe there and is in fact written with a Dokploy
host in mind — its prune timer exists because Dokploy's build cache fills disks.

## See also

- [Size the container resource limits](vm-resource-limits.md) — the container
  half of the same problem.
- [Reading `docker stats`](reading-docker-stats.md) — telling "busy" from
  "wrong".

_Verified against `main`@`3c56b41` on 2026-08-09._
