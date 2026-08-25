# The host resource guard

`scripts/host-resource-guard.sh` sets up the host-side half of keeping a small
VPS alive under load: the parts that cannot live in a compose file. Container
ceilings (`mem_limit`, `cpus`, `pids_limit`) belong in each stack's own compose.
This covers what those cannot reach.

| | |
|---|---|
| `earlyoom` | Kills one process before the box thrashes itself unreachable |
| `vm.swappiness` | Biases the kernel toward RAM until there is real pressure |
| Log rotation | Stops `json-file` logs from filling the disk |
| Prune timer | Stops Docker's build cache from filling the disk |

It carries a second, separate mode. `--sysbox` prepares the same host to run
devaloy with a nested Docker daemon, and it shares this file for one reason:
both modes write `/etc/docker/daemon.json`, and two scripts merging the same
file is how one of them quietly drops the other's keys. One writer, one merge
path. That mode has its own page —
[Prepare a host for Sysbox](prepare-a-host-for-sysbox.md) — and nothing below
applies to it.

Like `host-firewall-lockdown.sh`, this runs on the **host**, not inside the
container. `scripts/` is excluded from the Docker build context, so the file is
not in the image and nothing runs it for you. It needs `apt`, `systemd`, and
root, none of which a container has.

## Running it

Safe by default. With no arguments it only reports and writes nothing.

```sh
sudo ./scripts/host-resource-guard.sh --check
sudo ./scripts/host-resource-guard.sh --apply
```

The repo is not checked out on a Dokploy host as a normal clone (Dokploy clones
it under a hash-dependent path for the build), so clone it yourself or pull the
single file:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/host-resource-guard.sh \
  -o /tmp/host-resource-guard.sh
sudo bash /tmp/host-resource-guard.sh --check
```

| Flag | Effect |
|---|---|
| `--check` | Report only. The default. |
| `--apply` | Install and configure. Needs root. |
| `--restart-docker` | With `--apply`, also restart dockerd. **Bounces every container.** Off by default. |
| `--yes` | Skip the confirmation prompt. |

Tune it with environment variables rather than by editing the files it writes,
because `--apply` overwrites those every run: `SWAPPINESS`, `LOG_MAX_SIZE`,
`LOG_MAX_FILE`, `PRUNE_KEEP_HOURS`, `EARLYOOM_AVOID`, `EARLYOOM_PREFER`.

## What `--apply` writes

| Path | Content |
|---|---|
| `/etc/default/earlyoom` | `EARLYOOM_ARGS` with the avoid and prefer lists |
| `/etc/sysctl.d/99-devaloy-resources.conf` | `vm.swappiness`, `vm.vfs_cache_pressure` |
| `/etc/docker/daemon.json` | `log-driver` and `log-opts`, **merged** with `jq`, backed up first |
| `/etc/systemd/system/docker-prune.service` | `docker system prune` plus `docker builder prune` |
| `/etc/systemd/system/docker-prune.timer` | Sundays 04:00, 30 minute jitter |

It installs `earlyoom` from apt if the binary is missing, enables both systemd
units, and applies the sysctl live.

Three things it does **not** do. It sets no container limits, so `--check` will
still flag unlimited containers afterwards. It causes no container downtime
unless you pass `--restart-docker`. And it never prunes with `--volumes`, since
named volumes hold live site data.

`daemon.json` is the only file it merges rather than replaces, so Dokploy's own
keys survive. If `jq` is missing it skips that step with a warning instead of
risking the file.

The script is `set -euo pipefail`, so a failure partway through (a broken apt
mirror, say) stops there and leaves the earlier steps applied. Re-running is
safe.

### The first prune may run immediately

The timer is `Persistent=true`, so systemd runs a missed occurrence on
activation. A brand new timer has no stored timestamp, so the first prune
usually fires on `--apply` rather than waiting for Sunday.

That is normally what you want, since it reclaims stale images and build cache
straight away. Worth knowing before you run it on a box where you would rather
pick the moment.

## Verifying

```sh
sudo ./scripts/host-resource-guard.sh --check
```

That re-reports every control and flags any container still running without a
memory limit. Individually:

```sh
systemctl status earlyoom
systemctl list-timers docker-prune.timer
cat /proc/sys/vm/swappiness
docker info --format '{{.LoggingDriver}}'
```

Log rotation only reaches containers created **after** a dockerd restart, so
`daemon.json` showing the right values does not mean existing containers are
rotating. Recreate them, or restart dockerd in a maintenance window.

## Undoing it

Everything the script writes is a config file or a systemd unit. Nothing has
persistent state and nothing needs undoing in a particular order.

**All of it:**

```sh
sudo systemctl disable --now earlyoom docker-prune.timer
sudo rm -f /etc/sysctl.d/99-devaloy-resources.conf \
           /etc/systemd/system/docker-prune.service \
           /etc/systemd/system/docker-prune.timer
sudo systemctl daemon-reload
sudo sysctl --system
```

That leaves the `earlyoom` package installed but stopped. `sudo apt remove
earlyoom` if you want it gone entirely.

**Just the Docker log rotation.** Restore the backup the script took, picking
the timestamp from before the run:

```sh
ls -la /etc/docker/daemon.json.bak.*
sudo cp /etc/docker/daemon.json.bak.<timestamp> /etc/docker/daemon.json
sudo systemctl restart docker      # bounces every container
```

If there was no `daemon.json` before the run, the script created one containing
only its own keys, so deleting it returns you to stock:

```sh
sudo rm /etc/docker/daemon.json
```

**Just the swap tuning.** Removing the file reverts to the distro default of 60
on the next `sysctl --system` or reboot. To go back immediately without a
reboot:

```sh
sudo rm /etc/sysctl.d/99-devaloy-resources.conf
sudo sysctl -w vm.swappiness=60 vm.vfs_cache_pressure=100
```

**Just earlyoom**, keeping the rest:

```sh
sudo systemctl disable --now earlyoom
```

Note what reverting does not undo: any prune that already ran. Deleted images
and build cache are gone, and rebuild on the next deploy. Nothing in that path
touches volumes, so no site data is involved either way.

## See also

- [Prepare a host for Sysbox](prepare-a-host-for-sysbox.md) for the `--sysbox`
  mode of this same script.
- [reading-docker-stats.md](reading-docker-stats.md) for the columns this
  script's report is derived from.
- `scripts/host-firewall-lockdown.sh`, the other host-side script, covered in
  the [README](../../README.md).
