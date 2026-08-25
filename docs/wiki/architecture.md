# Architecture

devaloy is one `ubuntu:24.04` container running `tailscaled` and nothing else
resident. Everything else — the toolchain, the agents, your repos — lives in a
named volume that the container mounts. That split is the design: **the image is
disposable, the volume is not**, and every decision below follows from wanting
the box to be rebuildable without being fragile.

## Why one container

`tailscaled` runs *inside* this image rather than as a sidecar, which is the
opposite of how Tailscale is usually deployed alongside a service.

Tailscale SSH terminates the connection in whichever container runs the daemon
and spawns the login shell **there**. A sidecar sharing only the network
namespace would log you into the sidecar's filesystem — the one with no compiler,
no repos and no agents ([tailscale/tailscale#5215](https://github.com/tailscale/tailscale/issues/5215)).
Splitting them would mean giving up the thing the box exists for.

The consequence is that the container has `NET_ADMIN` and a `/dev/net/tun`
device, and that `tailscaled` is PID-1-adjacent rather than incidental: the
entrypoint's last act is `wait` on it, so the daemon dying takes the container
down and `restart: unless-stopped` brings it back.

## What runs, in what order

`entrypoint.sh` runs as root and its ordering is load-bearing. Roughly:

1. **Write `~/.devaloy_env`** and hook it into `.bashrc` and `.zshenv`. This is
   `PATH` and the OOM reset, and it is written first so the very first session
   that lands already has it.
2. **Write `~/.devaloy_secrets`** (mode 600) from the token variables — rebuilt
   from scratch every boot.
3. **Write `~/.config/agent-push.env`** if `NTFY_TOPIC` is set, same lifecycle.
4. **Sync `config/`** into `/home/dev` — see [Config as code](#config-as-code).
5. **Start `tailscaled` and `tailscale up --ssh`.**
6. **Start `dockerd`**, only when `WITH_DOCKER=true` and the engine is in the image.
7. **Run `bootstrap-toolchain.sh`** as the `dev` user.
8. **Run `link-shims`** to mirror mise's shims into `/usr/local/bin`.
9. **Authenticate `gh`**, then set the git identity, then install the signing key.
10. **Start `orca serve`**, only if the binary is present.
11. **Start the Paseo daemon** under a supervision loop, only when `WITH_PASEO=true`.
12. **`wait` on `tailscaled`.**

Three orderings in there matter more than they look.

**The tailnet comes up before the toolchain installs.** A cold volume takes
minutes to provision, and there is no sshd fallback. Doing it this way means the
box is reachable *during* that window rather than after it, so a bootstrap that
hangs is something you can watch and interrupt rather than something that leaves
you locked out.

**Orca starts after `link-shims`.** Orca shells out to `claude` and `codex`
through `su -l -s /bin/sh`, which does not get mise's shims on `PATH` — only
`/usr/local/bin`, which is exactly what `link-shims` populates. Start it any
earlier and agents launched from an Orca client die with `spawn codex ENOENT`.

**`dockerd` starts early, and that is the opposite call.** It sits between
`tailscale up` and the toolchain bootstrap, because it needs nothing from mise
and starting it there lets a cold volume pull project images while node is still
installing. It goes *after* `tailscale up` for a different reason: `dockerd`
writes iptables rules into the same network namespace `tailscaled` uses, so if
the two ever conflict you want that to show up as a broken project stack on a
box you can still log into, rather than as a box that never answers. The wait on
its socket is bounded at 30 seconds and nothing downstream depends on it.

### What is allowed to fail

Almost everything. `tailscale up` failing, the toolchain bootstrap failing,
`link-shims` failing, `gh auth login` failing, the signing key failing to
register — all log a `WARNING` and boot on.

This is deliberate rather than lax. A restart loop cannot fix a bad auth key or
a missing ACL rule, and it destroys the log that would tell you which one it
was. The failure modes are enumerated in
[Recover a box you cannot reach](recover-an-unreachable-box.md).

## Three layers of state

| Layer | Lifetime | Holds |
|---|---|---|
| The image | Rebuilt on `up --build` | `zsh`, `git`, `python3`, `vim`, `tmux`, `build-essential`, `bubblewrap`, `tailscale`, optionally Orca, optionally Docker Engine |
| `home` volume → `/home/dev` | Survives redeploys, dies with `down -v` | Repos, shell history, mise + the whole toolchain, agent credentials, skills |
| `tailscale-state` volume | Same | The node identity |
| `docker-data` volume → `/var/lib/docker` | Same | The nested daemon's images, containers and volumes. Only used when built `WITH_DOCKER=true`. |

Losing `tailscale-state` means the box rejoins the tailnet as a new machine,
under a new name, with the policy file no longer matching it.

`docker-data` is the one layer that is **pure cache**. Everything in it is
re-pullable or re-buildable, it is the largest thing on the box, and deleting it
reclaims that space without touching a single repo. Do not back it up; do back
up nothing else either, which is the point of the next paragraph.

The first one is why anything you `apt install` by hand is gone at the next
rebuild. A tool worth having belongs in the `Dockerfile`, or in
`bootstrap-toolchain.sh` if mise carries it.

**Neither volume is backed up.** There is no snapshot job in this stack. Pushing
to a remote is the backup, and unpushed work on the box is work that can be lost.

## Where the toolchain comes from

The image ships the OS-level tools. Everything a dev session actually reaches
for — `node`, `pnpm`, `gh`, `turbo`, `lazygit`, `herdr`, `claude`, `codex`,
`skills` — comes from **mise**, into the home volume, on first boot.

That placement is the point: an upgrade persists across a redeploy instead of
dying with the image. The agent CLIs come from mise's registry rather than their
own installers because mise fetches the same upstream artifacts, so there is one
package manager rather than three.

### The revision gate

`bootstrap-toolchain.sh` carries a `TOOLSET_REVISION` constant and writes it to a
marker in the home volume. The boot path re-runs the bootstrap only when the two
disagree.

This exists so an ordinary redeploy cannot re-resolve `@latest` and swap an agent
CLI out from under a live session. The cost is that **adding a tool without
bumping the revision means already-provisioned boxes never install it** — the
gate sees the marker, skips, and only `devaloy-update` picks it up by hand.

`devaloy-update` runs the same script with `--force`, which skips the gate
entirely, runs `mise upgrade` and re-runs the skills install. `mise install`
alone would not move a tool already on disk even if it is pinned to `latest`.

### Two `PATH` mechanisms

Shims resolve tool versions at exec time from the invoking user's mise config,
and they reach a shell two different ways because two kinds of session exist:

- **Interactive sessions** get them from `~/.devaloy_env`, sourced by `.zshenv`
  and prepended to the top of `.bashrc` — above Ubuntu's early-return guard for
  non-interactive shells.
- **Everything else** — `ssh devaloy '<cmd>'`, `scp`, `rsync`, git-over-ssh, and
  anything Orca spawns through `su -l -s /bin/sh` — finds them in
  `/usr/local/bin`, which `link-shims` mirrors and which is on every shell's
  default `PATH`.

The second mechanism exists because bash only auto-sources `.bashrc` in a
non-interactive shell when stdin is a socket, an OpenSSH detail that stopped
applying when sshd went away.

## Config as code

Shell and agent configuration lives in `config/` in the repo, not in dotfiles
hand-made on a box that might be rebuilt tomorrow:

```
config/
  zsh/zshrc            -> ~/.zshrc
  claude/              -> ~/.claude/     (settings.json, CLAUDE.md, statusline.sh, hooks/)
  codex/               -> ~/.codex/      (config.toml, AGENTS.md, hooks.json, rules/)
  bin/                 -> ~/.local/bin/  (agent-push — shared by both agents)
```

Two config directories deliberately stay out of this sync: the entrypoint copies
`config/docker/daemon.json` to `/etc/docker/daemon.json` and merges
`config/paseo/config.json` into `~/.paseo/config.json` itself, because neither
target lives under the plain `/home/dev` copy the sync performs.

**The repo wins.** Every shipped file is copied over its counterpart on each
boot, so editing one here and redeploying changes the box, and editing one *on*
the box does not survive.

**The copy is a merge, not a replace.** Anything the repo does not ship is left
alone: `~/.zshrc.local`, `~/.claude/.credentials.json`, `~/.codex/auth.json`,
session history, and skills installed by hand. That merge is why
`~/.local/bin` can be both mise's directory and a config target without one
destroying the other.

`~/.gitconfig` is the exception. It is not shipped as a file; the entrypoint sets
only the individual keys it owns (`user.name`, `user.email`, and the signing
keys), so aliases and diff tools you add survive.

Two things are deliberately not shipped from `config/`, because something else
already owns them and a vendored copy would fork at the next upgrade: **agent
skills**, installed from `mimukit/skills` by the skills.sh CLI, and **herdr's
agent-state hooks**, installed by `herdr integration install`. The `SessionStart`
entries that *call* those hooks are in `config/`; the scripts themselves are not.

## Security posture

The box has no public IP, no published ports, and no `ports:` key at all.
Tailscale SSH claims port 22 on the tailnet address inside the container's own
network namespace, so it never collides with the host's sshd and is not reachable
from the Docker host's interfaces.

There are no SSH keys, no `authorized_keys` and no host keys, because there is no
sshd. Authorization is tailnet identity plus the policy file, which means access
is revoked in the admin console rather than by editing a file on the box.

Three trades are worth knowing before running this anywhere sensitive:

- **`SYS_MODULE` is withheld.** It would let a process inside load kernel
  modules, which is close to a container escape on a box running arbitrary code
  and AI agents. The cost is that the *host* must have `tun` loaded.
- **Seccomp is off** (`security_opt: seccomp=unconfined`). Codex confines its
  shell with bubblewrap, which needs an unprivileged user namespace; Docker's
  default profile denies that and also blocks `pivot_root`, so `CAP_SYS_ADMIN`
  alone does not fix it. Leaving the filter on means the agent sandbox silently
  never engages. With it off, the host kernel is the only thing between a
  container process and the host — so run this on a host you would treat as
  disposable.
- **Docker, when built in, changes the container's authority.** `WITH_DOCKER=true`
  needs one of two keys, and they are not equivalent. `DEVALOY_RUNTIME=sysbox-runc`
  maps this container's root onto an unprivileged host user, so the nested
  daemon runs with no privileged flag and the host is no more exposed than
  before. `DEVALOY_PRIVILEGED=true` is all-or-nothing: every host device, so an
  agent here can mount the host disk. Use the first on any shared host and the
  second only on a machine you would treat as disposable. Under `sysbox-runc`
  two neighbouring keys stop meaning what their comments say: `cap_add:
  NET_ADMIN` is subsumed, because Sysbox gives container root the full
  capability set inside its own user namespace, and `seccomp=unconfined` is
  ignored, because Sysbox keeps its own filter on regardless. Neither costs
  anything — measured during the [Sysbox spike](../qa/qa-docker-runtime-sysbox-spike-2026-08-25.md),
  bubblewrap's user namespace works under both runtimes.
- **There is no delete guard.** An earlier revision routed every agent `rm`
  through a confirmation hook; it was removed because a permission prompt on
  every delete is exactly what stalls a session nobody is watching. What replaces
  it is scope — the only persistent state is `/home/dev` — plus the paths spelled
  out in `config/claude/CLAUDE.md` and `config/codex/AGENTS.md`.

### The OOM ladder

Compose sets the container to `oom_score_adj: -500`, keeping `tailscaled` off the
kernel's kill list — losing it severs the only route back in. `oom_score_adj` is
inherited, so four processes raise themselves back up: interactive shells to `0`,
and the Orca server, `dockerd`, and the Paseo supervisor to `-250`.

The resulting kill order is a runaway build first, then Orca, `dockerd`, and
Paseo, then `tailscaled` last. Raising an inherited value is unprivileged; only lowering needs
`CAP_SYS_RESOURCE`, which is why this works without extra capabilities. It is
also what makes a memory limit safe to set aggressively — see
[Size the container resource limits](vm-resource-limits.md).

## The optional Orca runtime

`WITH_ORCA` is a **build argument**, not an environment variable, so flipping it
requires `docker compose up -d --build`. It is off by default because it takes
the image from 683 MB to 1.6 GB, measured on arm64.

When present, the entrypoint supervises `orca serve` in an unbounded restart loop
behind `xvfb-run`. There is no runtime kill switch by design — stopping it means
`docker compose stop` or a rebuild with `WITH_ORCA=false`. One toggle, one
concept, at the cost of a rebuild to back out.

Upgrading Orca is also a rebuild: it is pinned by `ARG ORCA_VERSION` in the
`Dockerfile` and installed as a system package, which is a genuine break from how
every other tool on this box upgrades. Details are in
[Pairing the Orca apps](pair-the-orca-apps.md).

## The optional Docker runtime

`WITH_DOCKER` is a **build argument**, like `WITH_ORCA` and unlike `WITH_PASEO`,
so flipping it requires `docker compose up -d --build`. It is off by default and
costs about 460 MB of image.

When present, the entrypoint supervises `dockerd` in an unbounded restart loop
and logs to `/var/log/dockerd.log` rather than to the container log. The daemon
reads `/etc/docker/daemon.json`, which the entrypoint copies from
`config/docker/daemon.json` — its own copy line, because the ordinary config
sync targets `/home/dev` and `dockerd` reads `/etc/docker`. That file pins the
nested bridge into `10.x`; the reasoning is in `config/docker/README.md`, and
the short version is that both Docker's defaults and Dokploy's allocations come
out of `172.16/12`, so an unpinned nested daemon can collide with the container's
own `eth0`.

Two things follow from the daemon being *inside* the container, and they are the
whole reason it is there rather than on the host. A project's bind mount
resolves against `/home/dev`, where the repo actually is. A published port binds
inside this container's network namespace, so it is reachable over the tailnet
and not from the VPS public interfaces.

`docker-data` is what makes stacks survive a redeploy, and only for containers
whose compose file sets a `restart:` policy. The boot log prints whatever came
back.

## See also

- [Reference](reference.md) — the concrete variables, commands and paths behind
  everything above.
- [Getting started](getting-started.md) — the same system from the outside.

_Verified against `main`@`b6bc42b` on 2026-08-25._
