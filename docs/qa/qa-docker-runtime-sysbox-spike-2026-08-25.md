# QA: the Sysbox spike for Docker on devaloy

_Run 2026-08-25. This covers **Phase 0** and **Phase 4** of [`docs/plans/plan-docker-runtime-2026-08-25.md`](../plans/plan-docker-runtime-2026-08-25.md), grilled 2026-08-25._

_Venue: an **OrbStack Linux machine** named `devaloy`, Ubuntu 24.04.4 LTS on arm64, kernel `7.0.14-orbstack`, 7 CPUs, 2 GB RAM. Docker CE 29.7.2 from Docker's own apt repository. `sysbox-ce` 0.7.1 from the GitHub release, `sysbox-ce_0.7.1.linux_arm64.deb`._

## Verdict

**The plan proceeds, and one of its two gating fears is disproven.**

Every step passed. Step 3, the gate the plan called non-negotiable, passed: `tailscaled` opens `/dev/net/tun` under `sysbox-runc` and brings `tailscale0` up. Nested `dockerd` runs a two-service Compose stack with working bind mounts, published ports, service DNS and builds.

The headline change is step 2. The plan expected Sysbox to break Codex's bubblewrap sandbox and recorded a decision to ship anyway and accept the loss. **That loss does not occur.** Bubblewrap's user namespace works under `sysbox-runc`, and the one bubblewrap operation that does fail there fails on devaloy today as well. Sysbox is at parity, so the plan's Q13 fallback is not needed and the Phase 6 documentation must not claim a sandbox loss.

## What this venue does and does not prove

| Proves | Does not prove |
|---|---|
| The arm64 `sysbox-ce` deb installs on noble and registers the runtime | The amd64 deb, which is what the Dokploy host will use |
| `tailscaled` opens a `nobody:nogroup` tun device under `sysbox-runc` | That `tailscale up` joins a real tailnet under Sysbox (no auth key was used) |
| Which Compose keys Sysbox honours, ignores and subsumes | Behaviour under memory pressure with an agent fleet running |
| That the nested address pins take effect | Which ranges are free on the live Dokploy host |
| That the installer writes `bip` and `default-address-pools` itself | That it skips the Docker restart when they are pre-set |

The last row matters for Phase 5. This machine had no containers and no prior `daemon.json`, so the installer took the easy path and the "skip the restart" claim stayed untested. Phase 5 still has to prove it on a host that has both.

## Preconditions

```sh
orb create ubuntu:noble devaloy
```

Then inside the machine, Docker CE from Docker's apt repository, plus `jq`, which the Sysbox installer uses. `/dev/net/tun` already existed at mode `0666`, so no `modprobe tun` was needed.

## Step 1 — Install `sysbox-ce`

Kernel `7.0.14` is well past the 6.8 the changelog names, so ID-mapped mounts are available and `shiftfs` is not needed. `grep -c shiftfs /proc/filesystems` returns `0`, confirming the machine has none and does not want any.

```
Setting up sysbox-ce (0.7.1.linux) ...
Created symlink /etc/systemd/system/sysbox.service.wants/sysbox-fs.service → ...
Created symlink /etc/systemd/system/sysbox.service.wants/sysbox-mgr.service → ...
Created symlink /etc/systemd/system/multi-user.target.wants/sysbox.service → ...
```

`sysbox`, `sysbox-fs` and `sysbox-mgr` all report `active`. The install printed one warning, that `linux-headers-$(uname -r)` is absent and some workloads inside Sysbox containers expect it. Nothing in devaloy needs kernel headers, so this is noted and not acted on.

**The installer wrote the host's `/etc/docker/daemon.json` itself**, with no prompt and no container-removal error:

```json
{
    "runtimes": { "sysbox-runc": { "path": "/usr/bin/sysbox-runc" } },
    "bip": "172.20.0.1/16",
    "default-address-pools": [ { "base": "172.25.0.0/16", "size": 24 } ]
}
```

Two things follow for Phase 5. The `bip` and `default-address-pools` keys are exactly the ones the plan says to pre-set, so the shape is confirmed. And the ranges it picks unprompted are `172.20/16` and `172.25/16`, both inside `172.16/12`, which is where Dokploy allocates. On the live host that pick is a collision, which is the whole reason `--sysbox --apply` must take the ranges as arguments rather than guess.

## Step 2 — The user namespace test

The plan asked for two commands. Both are recorded below with a plain `runc` control, because the exit codes mean nothing without one.

### `unshare -U --mount-proc`

| Runtime | Output | Exit |
|---|---|---|
| `runc` (Docker default seccomp) | `unshare: unshare failed: Operation not permitted` | `1` |
| `sysbox-runc` | `unshare: mount /proc failed: Invalid argument` | `1` |

Read the two messages rather than the two exit codes. Under `runc` the `unshare -U` itself is denied. Under `sysbox-runc` the user namespace **is created** and only the `--mount-proc` remount inside it fails. That matches the wording in Sysbox's limitations doc, and it is a narrower failure than the plan assumed.

### `bwrap --unshare-user --dev-bind / / true`

| Runtime | Exit |
|---|---|
| `runc`, Docker default seccomp | `1` — `No permissions to create new namespace` |
| `runc`, `seccomp=unconfined` (**devaloy today**) | `0` |
| `sysbox-runc` | `0` |
| `sysbox-runc`, `seccomp=unconfined` | `0` |

**Bubblewrap's user namespace works under Sysbox**, with or without `seccomp=unconfined`.

### The operation that does fail, and where

Adding `--proc /proc`, which mounts a fresh procfs inside the new namespace:

```sh
bwrap --unshare-user --unshare-pid --dev-bind / / --proc /proc --tmpfs /tmp echo OK
```

| Runtime | Output | Exit |
|---|---|---|
| `runc`, `seccomp=unconfined` (**devaloy today**) | `Can't mount proc on /newroot/proc: Operation not permitted` | `1` |
| `runc`, `seccomp` and `apparmor` both unconfined | `Can't mount proc on /newroot/proc: Operation not permitted` | `1` |
| `runc`, `--privileged` | `OK` | `0` |
| `sysbox-runc` | `Can't mount proc on /newroot/proc: Invalid argument` | `1` |

The same as a non-root user inside the container fails the same way under both runtimes.

**This is the finding that reverses the plan's Q13.** Mounting a fresh procfs inside a nested user namespace fails on devaloy **as it is deployed today**, and only `--privileged` lifts it, because Docker's `/proc` mount masks are what block it. Sysbox does not take that capability away, because devaloy never had it. Whatever Codex's sandbox does on this box today, it does the same under `sysbox-runc`.

So the plan's recorded decision "ship Sysbox and accept Codex unsandboxed" is moot. Nothing is given up. Phase 3 step 5 and Phase 6 must both be written from parity, not from loss.

## Step 3 — `tailscaled` under `sysbox-runc`

The gate. It passes.

`/dev/net/tun` inside the container, as the plan predicted:

| Runtime | Owner | Mode |
|---|---|---|
| `runc` | `root root` | `crw-rw-rw-` |
| `sysbox-runc` | `nobody nogroup` | `crw-rw-rw-` |

Opening it read-write from inside a `sysbox-runc` container exits `0`. Mode `0666` is what carries it, exactly as the plan reasoned.

Running `tailscaled --state=mem: --tun=tailscale0` under both runtimes, through Compose, with devaloy's real key set:

```
3: tailscale0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280 qdisc pfifo_fast state UNKNOWN mode DEFAULT group default qlen 500
```

Identical under `runc` and `sysbox-runc`. The daemon reaches its steady idle state and reports `Tailscale is stopped`, which is the correct state for a node that has not run `tailscale up`.

Not proven here: an actual tailnet join. That needs a `TS_AUTHKEY` and belongs to Phase 4.

## Step 4 — What Sysbox does with the Compose keys already in the file

One container, devaloy's real key set, run under each runtime and asked what it got.

| Key | Under `runc` | Under `sysbox-runc` | Verdict |
|---|---|---|---|
| `oom_score_adj: -500` | `-500` | `-500` | **Honoured.** The OOM ladder survives. |
| `cap_add: NET_ADMIN` | `CapEff: 00000000a80435fb` | `CapEff: 000001ffffffffff` | **Subsumed.** Sysbox gives container root the full capability set, because that root is an unprivileged user on the host. `NET_ADMIN` is a subset of what it already has. |
| `security_opt: seccomp=unconfined` | `Seccomp: 0` | `Seccomp: 2` | **Ignored.** Sysbox installs its own seccomp notification filter and keeps it on regardless. |
| `pids_limit: 2048` | `pids.max 2048` | `pids.max 2048` | Honoured. |
| `mem_limit: 512m` | `memory.max 536870912` | `memory.max 536870912` | Honoured. |

The seccomp row answers open question 1 and triggers Phase 3 step 5. Note what it does **not** mean: Sysbox keeping a filter on does not break bubblewrap, as step 2 proves. Its filter traps and emulates rather than denying outright, which is the difference between Sysbox's filter and Docker's default profile.

The capability row is worth writing down for a different reason. `cap_add: NET_ADMIN` and the withheld `SYS_MODULE` both stop meaning anything under Sysbox, because the container gets every capability inside its own user namespace and none of them reach the host. The comments on those keys describe the `runc` shape, and they stay accurate only for that shape.

## Step 5 — Nested `dockerd` and a two-service stack

A `sysbox-runc` container running `ubuntu:24.04` with `docker-ce`, `containerd.io`, `docker-buildx-plugin` and `docker-compose-plugin`, starting its own `dockerd` with the `daemon.json` this plan intends to ship.

`dockerd` reaches `Daemon has completed initialization` and `API listen on /var/run/docker.sock` with no privileged flag and no socket mount.

| Check | Result |
|---|---|
| Socket appears | **1 second.** The plan's 30-second bound is generous, and can stay that way. |
| Storage driver | `overlayfs`, cgroup `cgroupfs` v2 |
| `docker0` address | `10.201.0.1/16`, from the shipped `bip` |
| Outer `eth0` | `172.20.0.2/16` |
| Compose stack, two services | `web running`, `cache running` |
| Project network subnet | `10.202.0.0/24`, from the shipped pool |
| Bind mount from the container filesystem | `HELLO_FROM_BIND_MOUNT` served over HTTP |
| Published port on `localhost` | Answers |
| Service-to-service DNS | `10.202.0.2  cache` |
| `docker build` inside | `BUILD_OK` |

Two notes.

**The address pin earns its place.** The outer `eth0` sits at `172.20.0.2/16` here. An unpinned nested `docker0` takes `172.17.0.1/16`, and both live inside `172.16/12`, which is the range Dokploy allocates from. Pinning to `10.x` removes the question.

**The storage driver is `overlayfs`, not `overlay2`.** Docker 29.7.2 enables the containerd snapshotter by default and reports the driver under that name. This is a Docker version change, not a Sysbox effect, and it is not the `vfs` fallback the plan was guarding against. Phase 4 step 5 should check for `overlayfs` or `overlay2` and treat only `vfs` as the failure.

Nothing here fell back to `vfs`, and the two nftables warnings in the daemon log (`delete table ip docker-bridges` … `No such file or directory`) are the normal first-boot messages from a daemon with no rules to clean up.

## What changes in the plan

| Plan item | Change |
|---|---|
| Q13, "if the spike fails" | **Void.** The spike did not fail, and the loss it planned around does not exist. |
| Open question 1, seccomp | Answered. Sysbox **ignores** `seccomp=unconfined`. Phase 3 step 5 fires. |
| Open question 1, `cap_add` | Answered. **Subsumed**, not ignored. |
| Open question 2, `oom_score_adj` | Answered. **Honoured** under `sysbox-runc`. |
| Open question 3, the tun device | Answered. `nobody:nogroup` at `0666`, opens, `tailscale0` comes up. |
| Phase 2 step 5, the socket wait | Confirmed generous. Keep 30 seconds. |
| Phase 4 step 5, `overlay2` | Accept `overlayfs` too. Fail only on `vfs`. |
| Phase 5, the range arguments | Reinforced. The installer picks `172.20/16` and `172.25/16` unprompted, which collides on the live host. |

## Still unproven after this pass

- **The amd64 deb.** Everything here is arm64.
- **A real tailnet join under Sysbox.** `tailscaled` starts and the interface comes up; nothing has authenticated.
- **The installer skipping the Docker restart.** Untested, because this machine had nothing to bounce.
- **Memory pressure.** The OOM ladder is proven as a number, not as a kill order under load.
- **Path MTU** from a nested container to another tailnet node, 1280 on `tailscale0` against 1500 on the nested bridge.
- **Codex's sandbox end to end.** Bubblewrap is proven at parity with today; the agent itself was not run.

---

## Phase 4 — the real stack on the same host

_Run 2026-08-25, same OrbStack machine, now running devaloy itself built from this branch with `WITH_DOCKER=true` and `DEVALOY_RUNTIME=sysbox-runc`._

### Verdict

**Every check that does not need a tailnet passed.** Two needed a `TS_AUTHKEY` and are recorded as unproven rather than passed.

One result is worth reading before the table: the address pin is not theoretical. devaloy's own `eth0` came up on `172.25.0.2/24`, allocated by the outer daemon from the pool the Sysbox installer set. An unpinned nested daemon allocates from `172.17.0.0/12`, which contains that address. The `10.x` pin is what stops a project network colliding with the box's own uplink.

### The image

Both builds ran on the same machine, minutes apart.

| Build | Size |
|---|---|
| `docker build` (default) | 918 MB |
| `docker build --build-arg WITH_DOCKER=true` | 1.38 GB |

**Delta: about 460 MB**, inside the plan's 400 to 500 MB estimate. Build time for the `WITH_DOCKER` layer alone was 54 seconds behind a warm apt cache.

Note the absolute numbers read higher than the 683 MB the README quotes for a default build. That figure predates both this branch and Docker 29's containerd snapshotter, which reports sizes differently. The delta is the number that transfers; the absolutes are venue-specific.

### Phase 1 gate

| Image | `dockerd` | `docker` CLI | `dev` groups |
|---|---|---|---|
| default | absent | absent | `dev` |
| `WITH_DOCKER=true` | 29.7.2 | Compose v5.5.0, buildx v0.36.1 | `dev`, `docker` |

The default build is unchanged, which was the plan's requirement for Phase 1.

### Phase 2 gate — boot order

```
[entrypoint] WARNING: tailscale up failed — this box is NOT reachable over the tailnet.
[entrypoint] WARNING:   docker compose exec devaloy tailscale up --ssh
[entrypoint] Docker daemon ready — logs in /var/log/dockerd.log
[entrypoint] Checking the mise toolchain
```

The Docker line lands after the `tailscale up` block and before the mise bootstrap, which is exactly the ordering the plan specifies. The `tailscale up` failure here is the absent auth key, and it demonstrates the intended property: a broken tailnet does not stop the daemon, and the daemon does not stop the toolchain.

### The nine checks

| # | Check | Result |
|---|---|---|
| 1 | Tailnet survives a nested stack | **Partial.** `tailscaled` stays alive and `tailscale0` stays up while `dockerd` writes its rules; the `DOCKER` nat chain and the tun interface coexist. A real tailnet join was not tested — no auth key. |
| 2 | Bind mount from `/home/dev` | **Pass.** Contents correct through the nested container, ownership `1000:1000` on both sides, and a `:ro` mount is enforced. |
| 3 | Published port | **Pass** on `localhost` from inside the box. `http://devaloy:3000` from a phone is unproven, same reason as row 1. |
| 4 | Service DNS and the subnet | **Pass.** `cache` resolves to `10.202.0.2`; the project network is `10.202.0.0/24` and `docker0` is `10.201.0.1/16`, both from the shipped `daemon.json`. |
| 5 | `buildx` and the storage driver | **Pass.** Build completes; driver is `overlayfs`, cgroup v2. Not `vfs`. |
| 6 | `docker-data` survives a redeploy | **Pass.** See below. |
| 7 | The OOM ladder | **Pass.** Login shell `0`, `dockerd` `-250`, `tailscaled` `-500`. Proven as numbers; not under real memory pressure. |
| 8 | Five services against `PIDS_LIMIT` | **Pass.** `pids.current` 198 against a ceiling of 2409, on a 2 GB host. |
| 9 | `devaloy-prune` | **Pass.** Reclaims cache and images, and the running project stack is still up afterwards. |

### Row 6, in detail, because the first attempt looked like a failure

A first redeploy brought nothing back and printed no restart line. That is correct behaviour, not a bug: the test project's compose file set no `restart:` key, so its containers carry policy `no` and Docker does not restart them with the daemon. `docker ps -a` showed them present and stopped, which is what proves `docker-data` survived.

Re-run with `restart: unless-stopped` on both services:

```
[entrypoint] Docker daemon ready — logs in /var/log/dockerd.log
[entrypoint] Nested containers restarted with the daemon:
[entrypoint]   proj-web-1 (nginx:alpine)
[entrypoint]   proj-cache-1 (redis:alpine)
```

and HTTP answered immediately after. The plan's claim is conditional on a restart policy and it holds exactly as written. The documentation says so rather than promising more.

### Phase 5 — the `--sysbox` mode, exercised

The code half of Phase 5 was tested on the same host. Steps 4 to 6 of that phase run on the live Dokploy host and were not performed.

| Case | Result |
|---|---|
| `--sysbox --check` | Reports kernel, Sysbox state, `jq`, the current `bip` and pools, and every Docker network and host interface subnet. Writes nothing. |
| `--sysbox --apply` with no ranges | Refuses, and names `--check` as the way to pick them. |
| `--sysbox --apply --bip 172.20.0.1/16` | Refuses. Real CIDR arithmetic caught the overlap against both the `bridge` network and the `docker0` interface. |
| `--sysbox --apply` with free ranges | Writes only the two keys, preserves the existing `runtimes` block, backs the file up, does not restart Docker, leaves every container running. |

`systemctl show docker --property=ActiveEnterTimestamp` was unchanged after the write, which is the check the docs tell an operator to run.

### Still unproven after Phase 4

- **A real tailnet join, and reaching a nested port from a phone.** Both need an auth key.
- **The amd64 path**, for the image and the Sysbox deb alike.
- **Memory pressure.** The OOM ladder is proven as three numbers, not as a kill order under load.
- **The live Dokploy host.** Phase 5 steps 4 to 6, including whether the Sysbox installer really skips its Docker restart when the two keys are pre-set. This machine had nothing to bounce, so that claim is still upstream documentation rather than a measurement.
- **Path MTU** from a nested container to another tailnet node.
