# Prepare a host for Sysbox

Read this before running devaloy with `WITH_DOCKER=true` on a host that serves anything else.

devaloy runs its own Docker daemon inside the container, and a daemon inside a container needs authority over its own namespaces. `DEVALOY_PRIVILEGED=true` grants that in one line and is the wrong answer here: privileged is all-or-nothing, so an agent on devaloy could mount `/dev/vda1` and rewrite every site on the machine. [Sysbox](https://github.com/nestybox/sysbox) is the other answer. It replaces `runc`, maps the container's root onto an unprivileged host user, and runs the nested daemon with no privileged flag and no socket mount.

Installing it is not hard. Installing it **without breaking the sites already on the host** takes four steps in a fixed order, and one of them is a maintenance window.

## The short path: a fresh VPS

On a host that serves nothing yet, `scripts/setup-sysbox-host.sh` runs the whole procedure in one shot: it checks the kernel, picks free `10.x` ranges, writes the two daemon.json keys, restarts Docker, installs the Sysbox deb, and verifies the result.

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/setup-sysbox-host.sh | sudo bash -s -- --yes
```

It refuses to guess ranges that collide with anything already on the host, and it warns and prompts when it finds running containers. On a host with live sites, skip it and follow the steps below instead; the restart in the middle is a maintenance window, and you want to choose when it happens.

## What the installer does if you let it

The Sysbox deb sets two keys in the host's `/etc/docker/daemon.json` and restarts Docker to apply them:

```json
"bip": "172.20.0.1/16",
"default-address-pools": [ { "base": "172.25.0.0/16", "size": 24 } ]
```

Those are its own picks, and both sit inside `172.16/12`, which is exactly where Dokploy allocates project networks from. On a host with existing stacks that is a collision, and a subnet collision does not announce itself: it presents as containers that cannot resolve each other, which is the last place anyone looks.

The restart is the other problem. It bounces every container on the host, at whatever moment the install happens to reach.

Both are avoidable. Set the two keys yourself, at ranges you chose, and take the restart at a time you pick. The installer then finds them already present and skips its own restart.

## The procedure

Everything below runs on the **Docker host**, not on devaloy.

### 1. Look, without writing

```sh
sudo ./scripts/host-resource-guard.sh --sysbox --check
```

This writes nothing. It reports the kernel version, whether Sysbox and `jq` are installed, what `bip` and `default-address-pools` are set to now, and every subnet currently in use — both Docker networks and host interfaces.

The kernel line is the one prerequisite you cannot work around. Sysbox needs ID-mapped mounts, which arrived in 5.12; its changelog names 6.8 and later. Below 5.12 you would need `shiftfs`, which is a different and worse story.

### 2. Pick ranges that miss everything

Take the subnet list from step 1 and pick a `bip` and a pool that overlap none of it. On a Dokploy host, anywhere in `10.x` is normally free, because Docker and Dokploy both allocate from `172.16/12`.

```sh
sudo ./scripts/host-resource-guard.sh --sysbox --apply \
  --bip 10.210.0.1/16 --pool 10.211.0.0/16/24
```

`--pool` is `BASE/PREFIX/SIZE`. `10.211.0.0/16/24` means "allocate `/24` networks out of `10.211.0.0/16`", which is 256 project networks.

Neither flag has a default and the script refuses to run without both. That is deliberate: a script that picks network ranges for a host serving live sites is the failure mode, not the convenience. It also does real CIDR arithmetic against the list from step 1 and refuses to write ranges that overlap something already in use.

The write is a merge, so Dokploy's keys and the log-rotation settings from the resource guard's own mode both survive. It backs the file up alongside first, and it **does not restart Docker and does not touch a single container**.

### 3. Restart Docker, deliberately

Nothing from step 2 is live until this runs, and this is the maintenance window:

```sh
sudo systemctl restart docker
```

**Every container on this host stops and starts.** Do it at a time you chose, and confirm every Dokploy service came back before continuing. Containers whose networks were on the old ranges get new addresses; that is the point of the exercise, and it is why this happens once, under supervision, rather than midway through an apt install.

### 4. Install Sysbox

```sh
curl -fsSLO https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb
sudo apt-get install -y ./sysbox-ce_0.7.1.linux_amd64.deb
```

Use `arm64` in place of `amd64` on an ARM VPS. `--sysbox --check` prints the exact line for the host it is running on, including the architecture, so copy it from there rather than from here.

The script does not run this for you. Installing a `runc` replacement on a host serving live sites is a decision, not a side effect of a script you ran to check something.

Then confirm two things:

```sh
systemctl status sysbox
systemctl show docker --property=ActiveEnterTimestamp
```

The first should be active. The second should still show the timestamp from step 3, which is how you know the installer did not restart Docker a second time.

### 5. Turn it on for devaloy

In the Dokploy Environment tab, or in `.env` for a hand-run stack:

```sh
WITH_DOCKER=true
DEVALOY_RUNTIME=sysbox-runc
```

Then redeploy **with a rebuild**, because `WITH_DOCKER` is a build argument. The boot log should show:

```
[entrypoint] Docker daemon ready — logs in /var/log/dockerd.log
```

## If the installer errors on existing containers

By default the Sysbox deb refuses to install while containers exist and tells you to run `docker rm $(docker ps -a -q) -f`. **Do not run that on a host with live sites.** It is the installer's shortcut for making sure nothing is running on the old network ranges, and steps 2 and 3 above already solved that problem properly.

If you reach that message, it means the two keys were not in place when the installer looked. Go back to step 1.

## What Sysbox changes about devaloy

Three keys in `docker-compose.yml` behave differently under `sysbox-runc`, and none of the differences cost anything. All three were measured; the numbers are in the [Sysbox spike](../qa/qa-docker-runtime-sysbox-spike-2026-08-25.md).

| Key | Under `runc` | Under `sysbox-runc` |
|---|---|---|
| `cap_add: NET_ADMIN` | Adds one capability | **Subsumed.** Container root gets the full capability set inside its own user namespace, and none of it reaches the host |
| `security_opt: seccomp=unconfined` | Removes Docker's filter | **Ignored.** Sysbox keeps its own filter on regardless. It traps and emulates rather than denying, so bubblewrap's user namespace still works |
| `oom_score_adj: -500` | Honoured | Honoured. The OOM ladder is unaffected |

`/dev/net/tun` appears inside the container as `nobody:nogroup` rather than `root:root`. It is mode `0666`, so `tailscaled` opens it and the tailnet comes up normally.

## See also

- [The host resource guard](host-resource-guard.md) — the other mode of the same script, and the reason there is only one writer for `/etc/docker/daemon.json`.
- [Run a project stack on devaloy](run-a-project-stack.md) — what to do once this is done.
- [Deploy with Dokploy](deploy-with-dokploy.md) — where the two environment keys go.
