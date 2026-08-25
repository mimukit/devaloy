# Plan — Docker and Compose on devaloy

Drafted: 2026-08-25
Grilled: 2026-08-25
Status: ready for implementation

## Context

Most projects you open on devaloy carry a `docker-compose.yml` and need it to start the development stack. The box has no Docker client and no Docker daemon. `Dockerfile` installs the OS tools, `bootstrap-toolchain.sh` installs the dev tools into the home volume, and neither one includes Docker. So today those projects do not run at all.

The fix is a nested `dockerd` inside devaloy, gated by a `WITH_DOCKER` key, the way `WITH_ORCA` gates Orca. Two facts about where state lives decide this over a host socket mount.

**Bind mounts must resolve inside the box.** Repos live in the `home` named volume at `/home/dev`. A project compose file says `./:/app`. With the host socket, the Docker host resolves that path on its own filesystem, where `/home/dev/proj` does not exist. Every project stack breaks on its first bind mount.

**Published ports must land on the tailnet.** A nested container's `ports: 3000:3000` binds inside devaloy's own network namespace. `curl localhost:3000` works in a Tailscale SSH session, and `http://devaloy:3000` works from a phone. With the host socket, that port lands on the VPS public interfaces instead. That breaks the no-published-ports posture and puts a development database on the internet.

There is a third reason. The host socket is host root. An agent on this box has passwordless sudo, so `docker run -v /:/host` reads and writes every file on the Dokploy server, including the live sites that share it.

The Dokploy host does run live sites, so `privileged: true` is not available here: it grants all host devices, and an agent that mounts `/dev/vda1` owns the machine. **Sysbox is the answer.** It replaces `runc`, maps container root to an unprivileged host user, and runs a nested Docker daemon with no privileged flag and no socket mount. The privileged shape stays in the compose file for anyone running devaloy on a host they own alone.

Success looks like this. `WITH_DOCKER=true` and `DEVALOY_RUNTIME=sysbox-runc` in `.env`, then `docker compose up -d --build`. You SSH in, `cd` to a project, run `docker compose up -d`, and reach the app from your phone at `http://devaloy:3000`. The default build is unchanged: no Docker in the image, no privilege, no runtime override, no new volume in use.

## Verified during grilling

Read from the documentation and the repo rather than assumed, because each one changed a decision below.

| Claim | Evidence |
|---|---|
| Compose interpolates both new keys, boolean cast included | Tested 2026-08-25. `privileged: ${P:-false}` resolves to `true`, and `runtime: ${R:-runc}` to `sysbox-runc`, under `docker compose config`. Confirm `docker compose version` on the Dokploy host before relying on it. |
| Dokploy passes every compose key through | It runs `docker compose -p <app> up -d --build`. The one condition already documented in `deploy-with-dokploy.md` still holds: Compose Type stays **Docker Compose**, because Swarm ignores `privileged`, `devices` and `cap_add` alike. |
| The nested storage driver will be `overlay2` | A named volume sits on the host filesystem under `/var/lib/docker/volumes`, not on an overlay, so there is no overlay-on-overlay to fall back from. |
| Rootless `dind` does not avoid the privilege | Docker's own `dind-rootless` image still requires `--privileged`, for seccomp, AppArmor and the `/proc` mount masks. |
| Sysbox is maintained and covers noble | v0.7.1, 31 July 2026. The changelog names Ubuntu 24.04 on kernel 6.8 and later. `amd64` and `arm64` debs both ship. |
| **Sysbox blocks nested user namespaces** | Its limitations doc, unfixed: "Nested user-namespace — `unshare -U --mount-proc` fails with 'invalid argument'." Affected software is anything using the Linux user namespace. That is what Codex's bubblewrap sandbox does. |
| Sysbox device ownership is survivable here | Host devices exposed with `--device` appear as `nobody:nogroup`, and access fails only when the device denies others read and write. `/dev/net/tun` is mode `0666`, so `tailscaled` should still open it. |
| Sysbox can install without removing containers | The installer errors out on existing containers by default and tells you to run `docker rm $(docker ps -a -q) -f`. It skips the Docker restart entirely when `bip` and `default-address-pools` are already present in the host's `/etc/docker/daemon.json`. |
| The host's `daemon.json` already has an owner in this repo | `scripts/host-resource-guard.sh` writes it, and already carries `--check` as the default, `--apply`, `--restart-docker` (documented as bouncing every container) and `--yes`. It also installs a `docker-prune` service and timer. |
| The builder GC keys were renamed | `reservedSpace` and `defaultReservedSpace` are current. `keepStorage` and `defaultKeepStorage` are the old names. |
| `dockerd --ip` is scoped to the default bridge | Documented as the host IP for publishing ports from the default bridge, so whether Compose's user-defined networks inherit it is untested. One reason among several to leave publishing at `0.0.0.0`. |

## Design decisions (settled)

### Engine and toggle

| Decision | Resolution |
|----------|-----------|
| Nested daemon, not the host socket | A full `dockerd` runs inside the container. The three reasons are in the Context. The host socket is a permanent non-goal, not a fallback. |
| Where it installs | **`Dockerfile`, from Docker's own apt repo**, as one contiguous `WITH_DOCKER` block, following the Orca precedent. Docker Engine is a system daemon with `containerd`, `runc` and an iptables integration, so apt resolving the set in one transaction is worth more than the toggle convenience of a home-volume install. |
| The key | **`WITH_DOCKER`, a build argument**, default `false`, same family and shape as `WITH_ORCA`. Flipping it needs `docker compose up -d --build`. |
| The privilege gets its own key | **`DEVALOY_PRIVILEGED`, a runtime variable**, default `false`. One key for both would mean `WITH_DOCKER=true` silently granting host root. It survives the move to Sysbox as the documented dedicated-host shape, so a failed Phase 0 spike costs no compose rewrite. Sysbox rejects a privileged container itself, so no extra guard is needed against setting both. |
| The runtime is selectable | **`runtime: ${DEVALOY_RUNTIME:-runc}`**, so one compose file serves both shapes. |
| No `ports:` key | Unchanged. Nested containers publish inside devaloy's network namespace and reach you over the tailnet. |

### Host and runtime

| Decision | Resolution |
|----------|-----------|
| Where the privileged box would run | Nowhere, for now. The Dokploy host runs live sites, so **Sysbox is the shape this plan builds for**. The privileged shape stays documented for a host you own alone. |
| How Sysbox reaches the live host | **Pre-configure `bip` and `default-address-pools` in the host's `/etc/docker/daemon.json`, take one controlled Docker restart, then install.** No container removal. Read the host's existing `docker network ls` and current `bip` first, so the ranges do not collide with what Dokploy already allocated. |
| Who writes the host's `daemon.json` | **`scripts/host-resource-guard.sh`, extended with a `--sysbox` mode.** One writer, one merge path. A second script would silently drop the log limits the first one wrote, and `--apply`, `--restart-docker` and `--yes` already carry the right semantics, including the warning that a restart bounces every container. |
| The Sysbox spike comes first | **Phase 0 gates the plan.** Two commands answer whether `unshare -U` works under `sysbox-runc`, and everything downstream waits on the result. |
| If the spike fails | **Ship Sysbox anyway and accept Codex running unsandboxed.** Your call, recorded plainly: Sysbox still protects the host, so what is given up is the boundary between Codex and the rest of the box, meaning `/home/dev`, `~/.devaloy_secrets`, the GitHub token and the Claude credentials. Claude Code does not use bubblewrap and is unaffected. The agent rule below carries more weight in that world, and `seccomp=unconfined` loses its stated reason for being in the compose file. |

### Process and state

| Decision | Resolution |
|----------|-----------|
| Where `/var/lib/docker` lives | **Its own named volume, `docker-data`.** It keeps image layers out of the container writable layer and lets you delete every image without touching a repo. Do not enable Dokploy volume backups on it. |
| When the daemon starts | **After `tailscale up`, before the mise bootstrap** (`entrypoint.sh:266`). A deliberate break from Orca and Paseo, which start last because they shell out through `su -l -s /bin/sh` and need `link-shims` first. `dockerd` needs nothing from mise. Starting it here lets a cold volume pull an image while mise installs node. |
| Why after `tailscale up` | `dockerd` writes iptables rules into the same network namespace `tailscaled` uses. Bringing the tailnet up first means a rule conflict shows as a broken project stack on a reachable box, not as a box you cannot log into. |
| Supervision | Unbounded restart loop, 10 second sleep, `oom_score_adj` at `-250`, copied from the Orca block at `entrypoint.sh:543`. The OOM order holds: a runaway build at 0, then `dockerd` and Orca at -250, then `tailscaled` at -500. |
| Daemon logs | **`/var/log/dockerd.log` in the container.** `dockerd` is noisy at info level, and the entrypoint log is the only view of a `tailscale up` failure. The entrypoint prints one line naming the path. |
| The nested daemon ships a config | **`config/docker/daemon.json`**, copied to `/etc/docker/daemon.json` by the entrypoint's Docker block. Note the wrinkle: the normal config sync targets `/home/dev`, so this file needs its own copy line. It is the in-container analogue of what `host-resource-guard.sh` already does for the host. |
| The nested address space | **Pinned into `10.x`**: `"bip": "10.201.0.1/16"` and a `default-address-pools` base of `10.202.0.0/16` at size 24. A nested `docker0` defaults to `172.17.0.0/16`, and Dokploy puts devaloy's own `eth0` on a bridge inside `172.16/12`. An overlap breaks routing inside the box and presents as a DNS failure. |
| Log and cache limits | In the same file: `log-opts` at `max-size: 10m` and `max-file: 3`, plus `builder.gc.enabled` with `defaultReservedSpace: "10GB"`. Use `reservedSpace`, not the old `keepStorage`. |
| Pruning | **Build-cache GC on its own, plus a hand-run `devaloy-prune`** next to `devaloy-update` in `/usr/local/bin`. No timer inside the box. The host timer prunes a host that runs services; this box runs an agent that may be halfway through a build. Cache is safe to reap automatically, images are not. |
| Published port binding | **`0.0.0.0`, accepted.** Same call the compose file already records for Orca's 6768: whoever holds the Docker host already holds the Docker socket. Narrowing to the tailnet IP would break `curl localhost:3000`, which is how most people test. |
| Stacks after a redeploy | **They come back, and the boot log says so.** `docker-data` survives, so any nested container with a restart policy starts again with `dockerd`. The entrypoint logs the running set once the daemon is ready, which turns a forgotten three-week-old stack from a surprise into a line you read on the way in. |
| Socket access | `usermod -aG docker dev` in the Dockerfile block, so `docker` needs no sudo. No `DOCKER_HOST` override anywhere. |
| `TOOLSET_REVISION` | Unchanged. Nothing here lands in the home volume, so the revision gate has nothing to gate. |

### Agent posture

| Decision | Resolution |
|----------|-----------|
| The agents get a Docker rule | **One rule in both `config/claude/CLAUDE.md` and `config/codex/AGENTS.md`**: use `docker` for project stacks only, never pass `--privileged` to a nested container, never mount a host path from outside `/home/dev`, and never edit `/var/lib/docker` by hand. This follows the precedent already in those files, which is how this box answers for having no delete guard. |
| No enforcing hook | Rejected on the repo's own history. The delete-guard hook was removed because a prompt on every call stalls a session nobody is watching. |

## Approach

Seven phases. Phase 0 is a spike and it gates the rest. Phases 1 to 3 are the code. Phase 4 proves it on a scratch host, which is the same machine Phase 0 uses. Phase 5 reaches the live host. Phase 6 is the documentation.

### Phase 0 — The Sysbox spike (built 2026-08-25)

**Ran 2026-08-25 on an OrbStack noble machine. All five steps passed. Results in [`docs/qa/qa-docker-runtime-sysbox-spike-2026-08-25.md`](../qa/qa-docker-runtime-sysbox-spike-2026-08-25.md).** One result reverses a decision above: bubblewrap's user namespace works under `sysbox-runc`, and the one operation that fails there fails identically on devaloy today, so **the "if the spike fails" row is void and Codex loses nothing**. Sysbox does ignore `seccomp=unconfined`, which fires Phase 3 step 5. The QA note carries the full list of plan items the results change.

On a scratch VPS, not the Dokploy host. Write the results into `docs/qa/`, following the existing QA notes. No code starts until this reports.

1. Install `sysbox-ce` v0.7.1. Confirm the kernel is 6.8 or later, so ID-mapped mounts are available and `shiftfs` is not needed. Install `jq` first, which the installer uses.
2. The headline test: `docker run --runtime=sysbox-runc ubuntu:24.04 unshare -U --mount-proc true`, then `bwrap --unshare-user --dev-bind / / true` in the same shape. Record both exit codes verbatim.
3. Does `tailscaled` come up under `sysbox-runc` with `devices: /dev/net/tun`? The device appears `nobody:nogroup` and is mode `0666`, so it should open. Prove it, because nothing else in this plan matters if the tailnet does not come up.
4. What does Sysbox do with the compose keys already in the file? Test `security_opt: seccomp=unconfined`, `cap_add: NET_ADMIN` and `oom_score_adj: -500` under `sysbox-runc`, and record whether each is honoured, ignored, or rejected outright. The OOM ladder depends on the third one.
5. Run a nested `dockerd` and a two-service compose stack, to confirm Docker-in-Sysbox works before any devaloy code exists.

Verifiable when: `docs/qa/` holds a note with five recorded results, and step 3 passed. If step 2 failed, the plan proceeds anyway under the decision above, and Phase 3 records that `seccomp=unconfined` no longer buys what its comment claims.

### Phase 1 — Install the engine behind the key (built 2026-08-25)

Edit `Dockerfile` only. The default build must come out byte-identical to today's.

1. In the `fetch` stage, next to the Tailscale keyring block at `Dockerfile:34`, fetch Docker's apt key from `https://download.docker.com/linux/ubuntu/gpg` into `/out/usr/share/keyrings/docker.asc` and write `/out/etc/apt/sources.list.d/docker.list` for `noble stable`, reading the architecture from `dpkg --print-architecture` the way the Orca fetch already does.
2. In the final stage, add one contiguous `ARG WITH_DOCKER=false` block, after the Orca block and before the `COPY --chmod=755 entrypoint.sh` line at `Dockerfile:207`, so editing the entrypoint or `config/` never rebuilds the package install.
3. Install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` and `docker-compose-plugin` behind the same apt cache mounts every other layer uses.
4. Run `usermod -aG docker dev` inside the block. The `docker` group does not exist until the package lands, so this cannot move up to the `useradd` line.
5. Assert in the build, the way the Orca block asserts: `[ -x /usr/bin/dockerd ]`, `docker compose version` exits 0, and `docker buildx version` exits 0. All three run without a daemon.
6. Add `devaloy-prune` to the existing `COPY --chmod=755 bootstrap-toolchain.sh devaloy-update link-shims /usr/local/bin/` line at `Dockerfile:208`.
7. Measure and record the image delta with `WITH_DOCKER=true`, on both amd64 and arm64. The estimate is 400 MB to 500 MB. The README quotes a measured number for Orca and must quote one here.

Verifiable when: a plain `docker compose build` produces an image with no `dockerd`, and `WITH_DOCKER=true docker compose build` produces one where `docker exec devaloy dockerd --version` answers.

### Phase 2 — Start and supervise the daemon (built 2026-08-25)

Edit `entrypoint.sh`, and add `devaloy-prune` at the repo root next to `devaloy-update`.

1. Add one section between the `tailscale up` block ending at line 266 and the mise bootstrap starting at line 268.
2. Gate on `WITH_DOCKER` and on `/usr/bin/dockerd` being present, and handle three cases distinctly. Key off: silent, because that is the default build. Key on and the binary missing: `WARNING` saying `WITH_DOCKER` is a build argument and this deploy needs `--build`. Key on, binary present, daemon fails to start: `WARNING` naming `DEVALOY_RUNTIME` and `DEVALOY_PRIVILEGED` as the two things to check.
3. Copy `config/docker/daemon.json` to `/etc/docker/daemon.json` before starting the daemon. This is its own copy line, because the config sync at `entrypoint.sh:159` targets `/home/dev`.
4. Start `dockerd` as root in a subshell, with `echo -250 > /proc/self/oom_score_adj`, output appended to `/var/log/dockerd.log`, inside an unbounded `while true` restart loop with `sleep 10`.
5. Wait for `/var/run/docker.sock`, bounded at roughly 30 seconds. On success, log one line naming the log path and one line listing any containers that restarted with the daemon. On timeout, log one `WARNING`. Never block the boot past the timeout: the tailnet and the mise bootstrap must not wait on Docker.
6. Write `devaloy-prune`: `docker builder prune` plus `docker image prune` with an age filter, printing reclaimed space. It never touches a running container and never runs on a timer.
7. Write the block comment in the house style. State why this one starts early while Orca and Paseo start late, and why it starts after `tailscale up` rather than before.

Verifiable when: the entrypoint log shows the Docker line before the mise line on a cold volume, and `docker info` works from a Tailscale SSH session.

### Phase 3 — Shipped config, compose keys and `.env` (built 2026-08-25)

1. Write `config/docker/daemon.json` with the `bip`, `default-address-pools`, `log-opts` and `builder.gc` settings from the decisions above.
2. Add the Docker rule to `config/claude/CLAUDE.md` and `config/codex/AGENTS.md`, in the register those files already use.
3. `docker-compose.yml`: add `WITH_DOCKER: ${WITH_DOCKER:-false}` to `build.args`, `WITH_DOCKER=${WITH_DOCKER:-false}` to `environment`, then `privileged: ${DEVALOY_PRIVILEGED:-false}`, `runtime: ${DEVALOY_RUNTIME:-runc}`, the `docker-data:/var/lib/docker` mount and the `docker-data` volume declaration.
4. Write the compose comment. It must say what `privileged` grants, that it is all-or-nothing, that a shared host is why this deployment uses `sysbox-runc` instead, and that Sysbox rejects a privileged container so the two keys cannot both apply.
5. If the Phase 0 spike found that Sysbox ignores `seccomp=unconfined`, amend that key's existing comment. Its current text claims a purpose it no longer serves under this runtime.
6. Add all three keys to `.env.example` near the `WITH_ORCA` entry at line 80, and spell out both shapes as literal blocks: shared host with `DEVALOY_RUNTIME=sysbox-runc`, and dedicated host with `DEVALOY_PRIVILEGED=true`.

Verifiable when: `docker compose config` with an empty `.env` shows `privileged: false`, `runtime: runc` and no build argument change, and each shape's `.env` produces the expected output.

### Phase 4 — Prove it on the scratch host (built 2026-08-25)

**Ran 2026-08-25. Seven of the nine checks passed; two need a `TS_AUTHKEY` and are recorded as unproven. Results in [`docs/qa/qa-docker-runtime-sysbox-spike-2026-08-25.md`](../qa/qa-docker-runtime-sysbox-spike-2026-08-25.md).** Two corrections to the steps below: the storage driver reports as `overlayfs` on Docker 29, not `overlay2`, and only `vfs` is a failure; and step 6 holds only for a nested container whose compose file sets a `restart:` policy, which is what the documentation now says.

Same machine as Phase 0, now running the real stack under `sysbox-runc`. Test in this order, because the first failure invalidates the rest.

1. The tailnet survives. Bring up a real project stack and confirm SSH holds and `tailscale status` stays healthy. This is the iptables coexistence question, and a wrong answer locks you out.
2. A bind mount from `/home/dev/<project>` reaches the nested container with the right contents and the right ownership. Sysbox's ID-mapped mounts make this worth checking explicitly.
3. A published port answers on `localhost` from an SSH session, and on `http://devaloy:<port>` from a phone.
4. Service-to-service DNS works between two nested containers on a project network, and the nested subnet is in `10.x` as configured.
5. `docker buildx build` completes, and `docker info` reports `overlay2` rather than `vfs`.
6. `docker-data` survives a redeploy, and the boot log lists the stack that came back.
7. The OOM order holds. Under memory pressure the build dies, not `tailscaled`.
8. A five-service stack does not hit `DEVALOY_PIDS_LIMIT`. Record the process count and revisit `docs/wiki/vm-resource-limits.md`.
9. `devaloy-prune` reclaims space and leaves running containers alone.

### Phase 5 — Reach the live host

**Steps 1 to 3 are built (2026-08-25) and exercised on the scratch host. Steps 4 to 6 run on the live Dokploy host and are not done.** The phase carries no built stamp until they are.

1. Extend `scripts/host-resource-guard.sh` with a `--sysbox` mode, reusing its existing `daemon.json` merge. `--check` must report whether `bip` and `default-address-pools` are already present and what the current Docker networks use, and must write nothing.
2. `--sysbox --apply` writes only those two keys and refuses to remove any container. It never installs the deb itself: it prints the exact `apt-get install ./sysbox-ce_*.deb` line and stops, so the operator installs deliberately.
3. Require the ranges as arguments or environment overrides rather than guessing them. A script that picks network ranges for a host serving live sites is the failure mode, not the convenience.
4. On the live host: run `--check`, choose ranges that do not collide, run `--sysbox --apply`, then one controlled `--restart-docker` at a time you choose. Confirm every Dokploy service came back before continuing.
5. Install `sysbox-ce`. Confirm `systemctl status sysbox` is healthy and that the installer did not restart Docker a second time.
6. Set `WITH_DOCKER=true` and `DEVALOY_RUNTIME=sysbox-runc` in the Dokploy Environment tab, use **Preview Compose** to confirm both keys survived, then deploy with a rebuild.

### Phase 6 — Documentation (built 2026-08-25)

1. `README.md`: a new section modelled on the Orca one at line 330, saying `--build` is not optional. Add the tool to the image contents table at line 60. Extend the "these look alike and are not" paragraph at line 420, which now covers a build argument (`WITH_DOCKER`) and two runtime keys.
2. `docs/wiki/architecture.md`: a fourth row in the three-layers-of-state table for `docker-data`, a `dockerd` step in the boot order list, and a security-trades entry that states the Sysbox posture and, if the spike failed, the Codex sandbox loss.
3. `docs/wiki/deploy-with-dokploy.md`: the Sysbox prerequisite, a `docker-data` row in the §7 volume table, and troubleshooting rows for the two failure modes from Phase 2 step 2.
4. `docs/wiki/reference.md`: the three new keys, `devaloy-prune`, and the `/var/log/dockerd.log` path.
5. A new wiki page for the host-side Sysbox procedure, wrapping the `--sysbox` mode with the range-collision check and the restart window.
6. A new how-to page on running a project stack: where the repo goes, how to reach a port from a phone, and when to run `devaloy-prune`.

### Alternatives rejected

- **Mount the host Docker socket.** Bind mount paths resolve on the host and break every project. Published ports land on the VPS public interfaces. Any agent gets host root over the neighbours. A permanent non-goal.
- **`privileged: true` on the shared host.** An agent can mount the host disk and reach the live sites. This is the whole reason Sysbox is in the plan.
- **Rootless `dockerd` inside the container.** It does not remove the privilege. Docker's `dind-rootless` image still requires `--privileged`, and forcing it unprivileged reports `newuidmap: open of uid_map failed` and a read-only sysfs mount.
- **Static Docker binaries into the home volume.** It would drop the `--build` requirement, and a compose change is needed for the runtime key anyway, so it saves nothing real while putting the `containerd` and `runc` upgrade path on this repo.
- **A separate Docker host over the tailnet.** Keeps devaloy unprivileged and breaks bind mounts again, because the paths must exist on the remote machine.
- **A second `install-sysbox.sh` script.** Two writers for one `daemon.json`, and the second one drops the first one's log limits.
- **`dockerd --ip <tailnet-ip>`.** Breaks `curl localhost:3000`, and the flag is documented for the default bridge, so Compose's own networks may not inherit it.
- **A prune timer inside the box.** It can delete an image an agent is mid-build on. The host timer is not a precedent, because the host runs services rather than agents.

## Open questions

Everything here waits on Phase 0. None of it blocks starting.

1. Does Sysbox honour, ignore, or reject `security_opt: seccomp=unconfined` and `cap_add: NET_ADMIN`? If it ignores them, they stay in the file for the privileged shape, and their comments need rewriting.
2. Does `oom_score_adj: -500` survive under `sysbox-runc`? The whole OOM ladder rests on it, and Sysbox virtualizes parts of procfs.
3. Does `tailscaled` open a `nobody:nogroup` `/dev/net/tun`? Expected yes at mode `0666`, unproven.
4. Which `bip` and `default-address-pools` ranges are free on the live host? Answered by `--check` on that machine, not before.
5. What do `DEVALOY_MEM_LIMIT` and `DEVALOY_PIDS_LIMIT` need to be once a five-service stack shares the cgroup? Phase 4 step 8 produces the number.
6. Does a nested container reaching another tailnet node hit a path MTU problem, at 1280 on `tailscale0` against 1500 on the nested bridge? A QA line, not a blocker.

## Non-goals

- **No host socket mount, ever.**
- **No automatic image pruning.** Build-cache GC is not image pruning, and the distinction is deliberate.
- **No Kubernetes, no Swarm and no `kind` inside the box.** Compose is the target.
- **No fix for Codex's sandbox under Sysbox.** If Phase 0 finds `unshare -U` blocked, that loss is accepted rather than worked around. Sysbox still protects the host; the boundary given up is the one between Codex and `/home/dev`.
- **devaloy does not become a deploy target.** Nested stacks are development stacks, and the tailnet stays the only route in.
- **No change to the default build.** With `WITH_DOCKER` unset, the image, the privilege, the runtime and the volume set are exactly what they are today.
