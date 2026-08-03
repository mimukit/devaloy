# devaloy

A portable, self-contained Docker Compose dev box you SSH into and pick up a
coding session from any device — phone or laptop, on any network. It exists so
development itself can happen remotely, independent of the machine physically in
front of you.

Reachable **only** through [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh),
never on any public IP and never on any published port. There are no SSH keys to
manage: `tailscaled` terminates the connection itself and authorizes you from
your tailnet identity plus your tailnet policy file. Tools and cloned repos
survive container restarts and redeploys.

## How it works

- One container: `ubuntu:24.04` running `tailscaled` with `--ssh`, plus a single
  non-root `dev` user with passwordless sudo.
- **No sshd, no `authorized_keys`, no host keys.** Tailscale SSH claims port 22
  on the tailnet address only, inside the container's own network namespace.
  Nothing is published to the Docker host.
- `tailscaled` runs *inside* this image rather than as a sidecar on purpose.
  Tailscale SSH spawns the shell in whichever container runs the daemon, so a
  sidecar sharing only the network namespace would log you into the sidecar
  ([tailscale/tailscale#5215](https://github.com/tailscale/tailscale/issues/5215)).
- [herdr](https://herdr.dev/) gives you a persistent, reattachable terminal
  session across devices — start it once, reattach from anywhere.
- `mise` installs and pins the rest of the toolchain (node, pnpm, gh, turbo,
  herdr) into the persistent home volume.
- `zsh` is the login shell, configured from [`config/zsh/zshrc`](config/zsh/zshrc)
  in this repo rather than from something you set up by hand on the box.

## What's on the box

From the image, available the moment you can log in:

| | |
|---|---|
| Shell | `zsh` (login shell), `bash`, `tmux` |
| Editors / viewers | `vim`, `bat`, `htop`, `btop` |
| Languages | `python3` (with `pip`, `venv`, and `python` aliased to it) |
| Build | `build-essential`, `git`, `curl`, `jq` |
| Agent sandbox | `bubblewrap` (`bwrap`), what Codex confines its shell with |
| Optional | the Orca runtime (`orca-ide`), only when built with `WITH_ORCA=true` — see [(Optional) the Orca apps](#optional-the-orca-apps) |

From `mise` on first boot, into the home volume: `node` (LTS major pin), `pnpm`,
`gh`, `turbo`, `lazygit`, `herdr`, plus [Claude Code](https://claude.com/claude-code)
(`claude`) and [Codex](https://github.com/openai/codex) (`codex`) — and
[`skills`](https://www.skills.sh), which then installs the agent skills both
CLIs share. See [Agent skills](#agent-skills).

The agent CLIs come from `mise` rather than their own installers because
`mise`'s registry fetches the same upstream artifacts — Claude Code's binary
checksummed against its release manifest, Codex's musl build from its GitHub
release — with nothing for this repo to hand-roll. They land in the home volume
like every other tool, so a `devaloy-update` upgrade survives a redeploy. Pin
either by pinning it in `bootstrap-toolchain.sh`.

The trade is that a **cold volume takes a few minutes longer to boot**, since
both are large downloads. The tailnet comes up before the toolchain install, so
you can log in and watch it happen rather than waiting for it.

Anything you `apt install` on the box yourself is gone at the next
`docker compose up --build`. If a tool is worth having, put it in the
`Dockerfile` — or in `bootstrap-toolchain.sh` if `mise` has it.

**Adding a tool to `bootstrap-toolchain.sh` means bumping `TOOLSET_REVISION` in
the same file.** The boot bootstrap skips itself when the home volume already
records the current revision, so without the bump a box that is already
provisioned will never install the new tool — it will keep skipping, and only
`devaloy-update` will pull it in by hand.

## One-time setup

### 1. Host prerequisite

The container needs the `tun` module on the Docker host. Most hosts already have
it; load it if `/dev/net/tun` is missing:

```sh
sudo modprobe tun
```

`SYS_MODULE` is deliberately not granted to the container — it would let a
process inside load kernel modules, which is close to a container escape on a
box that runs arbitrary dev code and AI agents.

Seccomp, on the other hand, *is* turned off (`security_opt: seccomp=unconfined`
in the compose file). Codex confines its shell with `bubblewrap`, which has to
create an unprivileged user namespace, and Docker's default seccomp profile
denies that — adding `CAP_SYS_ADMIN` isn't enough, it blocks `pivot_root` too.
Leaving the filter on means the agent sandbox silently never engages, which is
the worse of the two risks on a box whose whole job is running agents. With it
off, the host kernel is the only thing between a container process and the
host, so run this on a VPS you're willing to treat as disposable.

### 2. Tailnet policy file

Tailscale SSH is deny-by-default: without a rule you can join the tailnet and
still not be able to log in. Add this to the `ssh` section of your
[policy file](https://login.tailscale.com/admin/acls):

```json
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["dev"]
    }
  ]
}
```

`autogroup:self` means "devices owned by the same user as the connecting
device", which is why the auth key below must be **untagged**. Use `"action":
"check"` instead of `"accept"` if you want periodic browser re-authentication —
be aware that is painful from a phone.

### 3. Auth key

Generate a **reusable, non-expiring, untagged** key:
https://login.tailscale.com/admin/settings/keys

Then copy `.env.example` to `.env` and set `TS_AUTHKEY`:

```sh
cp .env.example .env
```

### 4. (Optional) GitHub token

Set `GITHUB_TOKEN` in `.env` to a personal access token and both `gh` and
`git push` over HTTPS are authenticated from first boot — no browser, no device
code, nothing to do on a phone. Classic tokens want `repo`, `read:org` and
`workflow`; fine-grained tokens want contents and pull-request access.

The entrypoint writes the token to `~/.devaloy_secrets` (mode 600) inside the
home volume, so **the volume now holds a live credential** — that is the cost of
skipping the interactive login. Clearing the variable and redeploying deletes
the file. Leave it empty to use `gh auth login` by hand instead; note that `gh`
refuses that flow while `GITHUB_TOKEN` is set, which is expected rather than a
fault.

### 5. (Optional) Claude Code token

Set `CLAUDE_CODE_OAUTH_TOKEN` in `.env` and Claude Code is authenticated from
first boot — no `/login`, no browser round-trip from a phone. Generate it on
your own machine, where a browser exists:

```sh
claude setup-token
```

That needs a Pro or Max subscription (or a Team/Enterprise seat); it opens the
same OAuth flow as `/login` and prints a token it does not store anywhere, so
copy it straight into `.env`. The entrypoint writes it to `~/.devaloy_secrets`
alongside the GitHub token, with the same consequence: **the home volume holds a
live credential**, and clearing the variable plus a redeploy is what revokes it.

Two things to know. The token is static and valid for **one year** with no
self-refresh — when it lapses, re-run `claude setup-token` and redeploy. And it
sits *above* `~/.claude/.credentials.json` in Claude Code's auth precedence, so
running `/login` on the box while this is set does nothing; leave the variable
empty if you want the interactive login to be the source of truth. (Codex has no
equivalent — it still wants `codex login` on the box.)

### 6. Start the stack

```sh
docker compose up -d --build
```

### 7. Disable key expiry

Once the node appears in the
[admin console](https://login.tailscale.com/admin/machines), **disable key
expiry on it**. A user-owned node key expires (~180 days by default), and an
expired node is unreachable — recovering it needs access to the Docker host.

## Connecting

From any device on your tailnet (laptop, or phone with the Tailscale app):

```sh
ssh dev@devaloy
```

No key, no port flag, no password. Tailscale SSH assumes port 22 and there is
no way to change it — but that port only exists on the tailnet address inside
the container, so it never collides with the host's own sshd.

If MagicDNS is off, use the node's `100.x.y.z` address instead of `devaloy`.

Then start (or reattach) your session:

```sh
herdr
```

Detach and reconnect from a different device — the session picks up where you
left off.

## (Optional) phone push notifications

Because you are not sitting in front of this box, nothing tells you when an agent
**blocks for permission** or **finishes a long turn**. Set a single `.env`
variable and it sends one [ntfy](https://ntfy.sh) push to your phone per session
— repo, state, elapsed — that updates in place:

```sh
NTFY_TOPIC=$(openssl rand -hex 16)   # this string IS the credential — keep it long and random
```

Redeploy, then subscribe to that topic in the ntfy app. Off by default; metadata
only, never prompt or code. Full details — security model, quota, tuning, and the
Android-16 caveat — are in
[docs/wiki/push-notifications.md](docs/wiki/push-notifications.md).

## (Optional) the Orca apps

Tailscale SSH gets you a terminal, which is everything a laptop or a phone with
an SSH client needs. The [Orca](https://www.onorca.dev/) desktop and mobile apps
are different — they talk to a *runtime*, not a terminal — so reaching them
means running one on the box. That is what `WITH_ORCA` builds in:

```sh
# in .env
WITH_ORCA=true
```

```sh
docker compose up -d --build
```

**`--build` is not optional.** `WITH_ORCA` is a build argument, so a plain
`docker compose up -d` will happily start the old image and leave you wondering
why nothing changed. This is the single easiest thing to get wrong here.

It is off by default because of what it costs: measured on `arm64`, the image
goes from **683 MB to 1.6 GB**. A box you only ever SSH into should not pay
900 MB for a runtime it never speaks to.

### Pairing

The server starts after the tailnet comes up and prints its pairing URL to the
container log — a non-obvious place to look, so that is the first place to look:

```sh
docker compose logs devaloy | grep -i pairing
```

Open that URL in the Orca desktop app.

For the phone, use the same log output — the server prints both an
`orca://pair?code=…` link and a `Web client URL:` line, and the Tailscale app
on the phone is what makes the address reachable.

Note that `--mobile-pairing` is a flag on **the** server, not a second command
you can run alongside it: Electron holds a single-instance lock per profile, so
a second `orca serve` in this container exits with `[single-instance] Another
Orca instance is already running`. There is no separate `orca pair` subcommand.
If the phone turns out to need a mobile-scoped code specifically, getting one
means changing the supervised launch in `entrypoint.sh` and rebuilding.

Paired devices are recorded under `~/.config` in the home volume, so they
survive `docker compose down && up` without re-pairing.

Nothing is published to reach any of this: `orca serve` binds port 6768 inside
the container's own network namespace, which the tailnet address already
reaches — the same reason Tailscale SSH works with no `ports:` key.

### What to know before you turn it on

- **Upgrading is a rebuild, not `devaloy-update`.** Orca is pinned by
  `ARG ORCA_VERSION` in the `Dockerfile` and installed as a system package.
  Bump it and rebuild. This is a genuine break from how every other tool on the
  box upgrades, and it will surprise you in three months.
- **There is no runtime kill switch.** Stopping a misbehaving Orca means
  `docker compose stop`, or `WITH_ORCA=false` and a rebuild. The entrypoint
  supervises it in an unbounded restart loop with a backoff, so killing the
  process just restarts it. This is deliberate — one toggle, one concept — but
  it does mean recovery costs a rebuild.
- **The updater chatters.** Orca's docs say a headless server never
  self-updates, but it logs `[autoUpdater] Checking for update` anyway. It
  cannot apply anything — `/opt` is root-owned and the server runs as `dev` —
  but the behaviour when an update *exists* is unobserved, and a check that
  downloads would land ~160 MB in the home volume.
- **Port 6768 is also reachable from the Docker host**, because `orca serve`
  binds `0.0.0.0` and has no bind-address flag. Not internet-exposed, and no
  worse than the Docker socket that host already has — but don't attach other
  containers to devaloy's network. See the comment in `docker-compose.yml`.
- **One box at a time.** Orca warns against two servers serving the same setup.
  `WITH_ORCA=false` being the default is most of the guard here; nothing stops a
  second devaloy from advertising itself if you deliberately turn it on twice.

## Updating the toolchain

The toolchain installs once per volume, so redeploys are predictable and never
swap a tool out from under a live session. To pick up newer versions or a
changed pin, run this on the box as `dev`:

```sh
devaloy-update
```

Pins live in `bootstrap-toolchain.sh`. Node is pinned to an LTS major; `gh`,
`pnpm` and `turbo` track latest. To pin herdr too, set `MISE_HERDR_VERSION` in
your `.env` and re-run `devaloy-update`.

It also reinstalls the agent skills, so it doubles as the publish loop — see
[Agent skills](#agent-skills). Use `skmi` when you want only that.

`devaloy-update` also refreshes `/usr/local/bin`, which is what makes the
toolchain visible to non-interactive sessions (`ssh devaloy '<cmd>'`, `scp`,
`rsync`, git-over-ssh). Run it after any `npm i -g`.

## Config as code

Shell and agent config live in [`config/`](config) in this repo, not in dotfiles
you set up by hand on a box you might rebuild tomorrow:

```
config/
  zsh/zshrc            -> ~/.zshrc
  claude/              -> ~/.claude/     (settings.json, CLAUDE.md, hooks/)
  codex/               -> ~/.codex/      (config.toml, AGENTS.md, hooks.json, rules/)
  bin/                 -> ~/.local/bin/  (agent-hook, rm-guard — shared by both)
```

Both agents run the same `agent-hook` dispatcher on every Bash call, which
routes deletes through `rm-guard`: temp files and git-tracked files pass, `rm
-rf` of a directory prompts, and `/home/dev` is refused outright. The toast and
worktree-cleanup features it carries on a Mac no-op here, by design.

Two things are deliberately **not** shipped from `config/`, because something
else already owns them and a copy here would fork on the next upgrade:

- **Skills** — installed from `mimukit/skills` by the skills.sh CLI. See
  [Agent skills](#agent-skills).
- **herdr agent-state hooks** — installed by `herdr integration install`, which
  `bootstrap-toolchain.sh` runs for both agents so a herdr pane shows
  working/idle. The `SessionStart` entries that call them are ours; the scripts
  are herdr's. `herdr integration status` shows what is installed.

**The repo wins.** Every file shipped under `config/` is copied over its
counterpart on each boot, so editing one here and redeploying actually changes
the box — and editing one *on* the box does not survive.

The copy is a merge, not a replace, so anything the repo does not ship is left
alone: credentials (`~/.claude/.credentials.json`, `~/.codex/auth.json`),
session history, and any hook or skill you added on the box by hand under a name
this repo doesn't use.

Your escape hatch for zsh is `~/.zshrc.local`, sourced last and never touched.
Claude Code and Codex have no equivalent include mechanism, so a setting you
want to keep has to go in `config/` — that is the trade for having the repo be
the source of truth.

## Agent skills

Skills are the one part of the agent setup this repo does **not** ship. They
live in their own repo — [`mimukit/skills`](https://github.com/mimukit/skills) —
and are installed from it by the [skills.sh](https://www.skills.sh) CLI, which
`bootstrap-toolchain.sh` runs on first boot:

```sh
skills add mimukit/skills --global --skill '*' -a claude-code -a codex -y
```

**Every skill in the repo, no curated list.** A kit you are still shaping is
exactly the one you want to reach from a phone, and curating would mean editing
this repo on every experiment. They install to `~/.agents/skills` with symlinks
into `~/.claude/skills` and `~/.codex/skills` — all inside the home volume, so
they survive a redeploy.

Publishing loop, once a skill is pushed to `mimukit/skills`:

```sh
skmi              # install/refresh every skill — what you want after publishing
skup              # update only what is already installed
devaloy-update    # the toolchain too; runs the same skmi command
```

`skmi`, not `skup`, is what picks up a **newly authored** skill: `skills update`
only refreshes skills already in the lockfile, so it will never notice one that
was not installed before. Nothing in this repo needs editing either way — the
`TOOLSET_REVISION` gate only governs the unattended boot path, and both commands
skip it.

Pulling from another repo works the same way and survives redeploys, but not a
volume reset unless you add it to `bootstrap-toolchain.sh`:

```sh
skills add <owner>/<repo> --global -a claude-code -a codex -y
skills use <owner>/<repo>@<skill>    # try one without installing it
skills remove <skill>                # until the next skmi reinstalls it
```

Some installed skills **cannot work on this box** and are documented as such in
`CLAUDE.md`/`AGENTS.md` rather than filtered out: `verifykit` needs a real
browser, and `orcakit` needs the Orca desktop app. `orca-cli` depends on the
build — it drives an Orca runtime, so it is inert on a stock box and works when
you build `WITH_ORCA=true`. An exclusion list would defeat the point of
`--skill '*'`.

## Recovering a box you can't reach

There is no sshd fallback by design, so the break-glass path is the Docker host:

```sh
docker compose exec devaloy tailscale status
```

```sh
docker compose exec devaloy tailscale up --ssh
```

## (Optional) hardening the host

On a cloud VPS, `scripts/host-firewall-lockdown.sh` locks down the *host's* own
firewall (deny incoming by default, allow only on the `tailscale0` interface) as
defense-in-depth. It refuses to run unless Tailscale is already up, to avoid
locking you out. This protects the host, not devaloy — devaloy already
publishes nothing. Skip it on a trusted/home Docker host.

```sh
sudo scripts/host-firewall-lockdown.sh
```

## Backup contract

There is no backup job and no snapshot tooling. `/home/dev` persists across
redeploys, but **git-push discipline is the only backup**: nothing valuable
should live only on devaloy. If the host or its volumes are lost, recovery is
re-cloning your repos and re-running `mise install`.

## Non-goals

- No browser-based IDE — SSH only.
- No mosh — herdr's reattach covers the reconnect case.
- No host Docker socket access — devaloy can't control the host's other
  containers.
- No public HTTPS domain, no Traefik, no Let's Encrypt.
- No SSH key management, no password auth, no fallback sshd.
