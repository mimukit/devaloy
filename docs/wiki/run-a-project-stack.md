# Run a project stack on devaloy

Once the box is built with `WITH_DOCKER=true`, running a project's development stack is the same three commands it is anywhere else. What is worth knowing is where the files go, how you reach a port from a phone, and what fills the disk.

If `docker info` fails, the box was not built with the key. Setting it in the environment is not enough — it is a build argument, so it needs `docker compose up -d --build` on the devaloy stack itself. See [(Optional) Docker and Compose](../../README.md#optional-docker-and-compose).

## Where the repo goes

Anywhere under `/home/dev`. That is the only directory that survives a redeploy, and it is also the only place a bind mount can safely point.

```sh
cd ~
git clone https://github.com/you/myapp
cd myapp
docker compose up -d
```

The daemon runs inside this container, so `./:/app` in the project's compose file resolves against `/home/dev/myapp` — the repo you just cloned. With the host's Docker socket it would resolve on the VPS filesystem, where that path does not exist, and every project would break on its first bind mount. That is the whole reason the daemon is nested.

File ownership passes through unchanged. A file owned by `dev` (uid 1000) in `/home/dev` shows as uid 1000 inside the nested container, so a project image running as uid 1000 can write to a mounted source directory without a `chown` dance.

**Never bind mount a path from outside `/home/dev`.** Mounting `/`, `/etc`, or a Docker socket into a nested container gives away the boundary the whole arrangement rests on. The rule is written into `config/claude/CLAUDE.md` and `config/codex/AGENTS.md` so the agents on the box follow it too.

## Reaching a port

A published port binds inside devaloy's own network namespace. Two routes reach it:

```sh
curl localhost:3000            # from a Tailscale SSH session on the box
```

```
http://devaloy:3000            # from a phone or laptop with Tailscale connected
```

Use the tailnet hostname you set as `TS_HOSTNAME`, or the `100.x.y.z` address from `tailscale ip -4`. MagicDNS on the client resolves the name; nothing needs to be configured on the box.

Ports bind `0.0.0.0`, so they are also reachable from the Docker host itself. That is accepted rather than firewalled, for the same reason the compose file already records for Orca's port 6768: anyone on the Docker host already holds the Docker socket and can `docker exec` in as root, so the port grants them nothing new. What matters is what does **not** happen — the port never lands on the VPS public interfaces, which is what a host socket mount would have done.

## Stacks and redeploys

`/var/lib/docker` is the `docker-data` named volume, so it survives a redeploy of devaloy itself. A nested container whose compose file sets a restart policy comes back with the daemon:

```yaml
services:
  web:
    image: nginx:alpine
    restart: unless-stopped
```

Without `restart:`, the container survives as a stopped container and you start it again by hand. Either way the images and volumes are still there; nothing re-pulls.

The boot log names whatever restarted, so you find out on the way in rather than when a port is already bound:

```
[entrypoint] Docker daemon ready — logs in /var/log/dockerd.log
[entrypoint] Nested containers restarted with the daemon:
[entrypoint]   proj-web-1 (nginx:alpine)
[entrypoint]   proj-cache-1 (redis:alpine)
```

## When the disk fills

Build cache is reaped for you. `config/docker/daemon.json` sets the builder GC to hold 10 GB, and it runs on its own.

Images are not, and that is deliberate: an agent may be halfway through a multi-stage build whose intermediate images are pinned by nothing. Reap them by hand:

```sh
devaloy-prune                  # dangling images and build cache older than 7 days
devaloy-prune --all            # also images no container is running
devaloy-prune --all --age 24h  # narrower window
```

Neither form can touch an image a running container uses — Docker refuses — so a stack you left up is safe by construction.

For the nuclear option, on the Docker host rather than on devaloy:

```sh
docker compose down
docker volume rm <appName>_docker-data
docker compose up -d
```

That reclaims every gigabyte of project images without touching a single repo, because repos live in `home` and images live in `docker-data`. Do not confuse the two volume names.

## When a stack will not start

The daemon logs to `/var/log/dockerd.log`, not to the container log, because `dockerd` at info level would bury the entrypoint's own output:

```sh
tail -50 /var/log/dockerd.log
```

Two failures have their own entries in [Deploy with Dokploy → Troubleshooting](deploy-with-dokploy.md#troubleshooting): the daemon not being in the image at all, and the daemon being present but unable to start.

## Limits worth knowing

- **Compose only.** Kubernetes, Swarm and `kind` inside the box are explicit non-goals.
- **devaloy is not a deploy target.** Nested stacks are development stacks. The tailnet stays the only route in, and nothing here is meant to serve production traffic.
- **A five-service stack is comfortable.** Measured on a 2 GB scratch host: 198 processes against a 2409 ceiling, with room left. If you run heavier stacks, size `DEVALOY_MEM_LIMIT` and `DEVALOY_PIDS_LIMIT` with [Size the container resource limits](vm-resource-limits.md).

## See also

- [Prepare a host for Sysbox](prepare-a-host-for-sysbox.md) — the host-side prerequisite.
- [Architecture → The optional Docker runtime](architecture.md#the-optional-docker-runtime) — why the daemon starts where it does in the boot order.
- [Reference](reference.md) — the three environment keys and `devaloy-prune`.
