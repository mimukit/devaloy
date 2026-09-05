# Migrate the box to a new host

There are two ways to move devaloy, and they differ in what crosses over. **Re-enrolling** deploys a fresh box on the new host and abandons the old volumes: you re-clone your repos and the toolchain reinstalls itself, which is fine when everything is pushed. **Moving the volumes** carries `/home/dev` and the Tailscale node identity across, which is the path when there is unpushed work, hand-installed credentials you cannot easily re-mint, or a warm toolchain you do not want to rebuild on a slow link.

Re-enrolling is the default. It is the box working as designed — the container is disposable, the repo rebuilds it — and it has no way to half-fail. Move the volumes only when they hold something a `git clone` will not bring back.

Either way, `docker-data` never moves. It is the nested Docker daemon's cache — images, containers, project volumes — and everything in it is re-pullable or re-buildable by the next `docker compose up` inside a project.

## Path 1: re-enroll fresh

1. On the old box, push everything. Unpushed work does not survive this path — check every repo:

```sh
for d in ~/projects/*/; do git -C "$d" status --short --branch; done
```

2. In the [Tailscale admin console](https://login.tailscale.com/admin/machines), delete the old node. Two live nodes cannot share a name, so skipping this gets the new box enrolled as `devaloy-1` while `ssh devaloy` still points at the corpse.

3. On the new host, deploy as if for the first time — [Getting started](getting-started.md) is the walkthrough. Mint a fresh `TS_AUTHKEY` (reusable, non-expiring, untagged, same as the original) rather than reusing one that may have expired.

4. Stop the old container. Tear it down whenever you are confident; `docker compose down -v` on the old host is the deliberate destruction of the old volumes.

Re-clone your repos, and the box is back. The toolchain, skills, and managed dotfiles all reinstall on first boot; what you re-enter by hand is whatever the repo does not ship — `gh`/agent credentials if you do not pass the tokens in `.env`, and anything in `~/.zshrc.local`.

## Path 2: move the volumes

Two volumes carry the state worth moving: `home` (repos, toolchain, credentials, history, skills) and `tailscale-state` (the node identity — moving it means the new host answers as the *same* tailnet node, no admin-console work needed).

1. Stop the container on the old host. Never copy the volumes under a live box:

```sh
docker compose down
```

2. Find the real volume names. Compose prefixes them with the project name, which is `DEVALOY_NAME` and defaults to `devaloy` — so `devaloy_home` on a stock box, the app name under Dokploy, and your own value on a second box. Confirm rather than guess:

```sh
docker volume ls | grep -E 'home|tailscale'
```

3. Pack each volume into a tarball using a throwaway container:

```sh
docker run --rm -v devaloy_home:/from -v "$PWD":/backup ubuntu \
  tar -czf /backup/home.tgz -C /from .
docker run --rm -v devaloy_tailscale-state:/from -v "$PWD":/backup ubuntu \
  tar -czf /backup/tailscale-state.tgz -C /from .
```

4. Copy both tarballs to the new host (`scp`, `rsync` — whatever you have).

5. On the new host, clone the repo, write `.env`, and create the volumes *without starting the box*, then unpack into them:

```sh
docker compose create
docker run --rm -v devaloy_home:/to -v "$PWD":/backup ubuntu \
  tar -xzf /backup/home.tgz -C /to
docker run --rm -v devaloy_tailscale-state:/to -v "$PWD":/backup ubuntu \
  tar -xzf /backup/tailscale-state.tgz -C /to
```

6. Start it:

```sh
docker compose up -d --build
```

Because the node identity moved, `TS_AUTHKEY` in `.env` may stay empty — on a redeploy with saved state the entrypoint passes no key and the node just comes back up. The toolchain marker moved with the home volume too, so the bootstrap skips itself and first boot is fast.

7. **Do not start the old container again.** Two containers holding the same node identity fight over it. Once the new box answers over `ssh devaloy`, retire the old host's copy for good.

If step 6 comes up unreachable, [Recover a box you cannot reach](recover-an-unreachable-box.md) applies unchanged — the break-glass paths do not care how the volumes got there.

_Verified against `main`@`a1f2d83` on 2026-08-25._
