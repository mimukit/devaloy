# Getting started

From a clone to a shell on the box. This walks the required path only — the
optional pieces (GitHub token, Claude Code token, signed commits, the Orca
runtime) each have their own section in the [README](../../README.md) and none
of them are needed to log in.

You need a Docker host you control and a Tailscale account. Budget a few
minutes for the first boot: the toolchain downloads into an empty volume.

## 1. Load `tun` on the Docker host

`tailscaled` cannot create its interface without it:

```sh
sudo modprobe tun
```

Most hosts already have it. Check for `/dev/net/tun` if you want to skip this.

The container is deliberately *not* granted `SYS_MODULE`, so it cannot load the
module itself — that capability is close to a container escape on a box that
runs arbitrary code and AI agents.

## 2. Clone the repo

```sh
git clone https://github.com/mimukit/devaloy.git
cd devaloy
```

## 3. Add an SSH rule to your tailnet policy file

Tailscale SSH is deny-by-default. Without this rule you can join the tailnet and
still not be able to log in. Add it to the `ssh` section of your
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

`autogroup:self` means devices owned by the same user as the connecting device,
which is why the auth key in the next step must be **untagged**.

## 4. Set an auth key

Generate a **reusable, non-expiring, untagged** key at
[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).

```sh
cp .env.example .env
```

Set `TS_AUTHKEY` in `.env` to that key. Every other variable can stay empty for
now; see [Reference](reference.md) for what each one does.

## 5. Start the stack

```sh
docker compose up -d --build
```

## 6. Watch it come up

```sh
docker compose logs -f devaloy
```

The tailnet comes up *before* the toolchain installs, so you will see this line
while node, pnpm, gh, herdr, Claude Code and Codex are still downloading:

```
[entrypoint] devaloy is up. Connect with: ssh dev@devaloy
```

That means you can log in now and watch the rest happen. `[entrypoint]
Toolchain ready` is the line that means the install finished.

If instead you see `WARNING: tailscale up failed`, stop here and go to
[Recover a box you cannot reach](recover-an-unreachable-box.md).

## 7. Disable key expiry on the node

Once the box appears in the
[admin console](https://login.tailscale.com/admin/machines), turn off key expiry
on it. A user-owned node key expires — around 180 days by default — and an
expired node is unreachable, which means recovering it from the Docker host.

Do this now. It is the one step that is easy to skip and painful to skip.

## 8. Log in

From any device on your tailnet:

```sh
ssh dev@devaloy
```

No key, no port flag, no password: `tailscaled` terminates the connection itself
and authorizes you from your tailnet identity plus the policy rule from step 3.
If MagicDNS is off, use the node's `100.x.y.z` address instead of `devaloy`.

## 9. Start a session that survives disconnects

```sh
herdr
```

Detach, reconnect from a different device, run `herdr` again — the session picks
up where you left off. This is what makes the box usable from a phone.

## What you have now

A container with `zsh`, `git`, `python3`, `vim`, `tmux`, `bat`, `htop`/`btop`
and `build-essential` from the image, plus `node`, `pnpm`, `gh`, `turbo`,
`lazygit`, `herdr`, `claude`, `codex`, `command-code` and `skills` installed into
`/home/dev` by `mise`.

`/home/dev` is a named volume, so clones, shell history and tool credentials
survive a redeploy. **Everything outside it is discarded on the next
`docker compose up --build`**, including anything you `apt install` by hand.

There is no backup job and no snapshot here. Pushing to a remote is the only
backup.

## Next

- Set the optional tokens so agents can commit and push without a browser —
  README sections [4](../../README.md#4-optional-github-token) through
  [6](../../README.md#6-optional-git-identity-and-signed-commits).
- [Size the container resource limits](vm-resource-limits.md), especially on a
  host shared with anything you care about.
- [Turn on push notifications](push-notifications.md) so you know when an agent
  blocks for permission.
- Read the [Architecture](architecture.md) page before changing anything.

_Verified against `main`@`b6bc42b` on 2026-08-25._
