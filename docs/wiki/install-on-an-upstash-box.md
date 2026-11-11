# Install on an Upstash Box

An Upstash Box is a small container that Upstash hosts. It pauses when idle, and a request to its preview URL wakes it again. One command turns a fresh box into a devaloy box that runs the T3 Code server: the same mise toolchain, skills and agent config as every other box, the `devaloy` CLI, and a pairing link for the T3 Code phone app. The phone reaches the server through the box's Upstash preview URL, so there is no VPS and no tailnet needed.

This is the third runtime, `RUNTIME=upstash`, beside the container and the [VM install](install-on-a-vm.md). It runs the same steps from `lib/system/` and `lib/steps/`. The Upstash init command does the work that `entrypoint.sh` or systemd does elsewhere: it runs `lib/steps/upstash-boot.sh` on every container start.

**The box must serve nothing else.** The box user `boxuser` has passwordless sudo, and the agents run in bypass permission mode as that user. Every file, token and service on the box is in reach of every agent session. There is no uninstall; to remove devaloy, delete the box.

## Before you start

You need:

- A fresh Upstash Box on the Node runtime. The installer refuses any other `UPSTASH_BOX_RUNTIME`, and needs Debian 12 or newer on `x86_64` or `aarch64`.
- Your Upstash API key. The installer uses it once, to set the box's init command and to open the public URL for port 3773.
- A shell on the box as `boxuser`, from the Upstash console or Upstash SSH.
- The T3 Code app on your phone.
- A `GITHUB_TOKEN`. It is optional in name only. Upstash Boxes share their outbound address, and on the first real box that address had used all 60 of GitHub's anonymous API calls per hour. mise resolves `latest` through that API, so a cold install with no token failed on a 403. The installer warns when fewer than 30 calls are left.
- Optional: a `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` on a machine with a browser, and the other tokens you use on your other boxes.

## 1. Write the env file first

The installer stores every setting in `/workspace/.devaloy/env`. You can pass a value as a variable on the command line, but then the token lands in your shell history. Write the file before the first run instead:

1. Make the directory. `/workspace` belongs to root on a new box, so this needs `sudo`:
   ```sh
   sudo install -d -o boxuser -g boxuser -m 700 /workspace/.devaloy
   ```
2. Create the file with mode 0600:
   ```sh
   install -m 600 /dev/null /workspace/.devaloy/env
   ```
3. Open `/workspace/.devaloy/env` in an editor.
4. Add one `KEY="VALUE"` line for each value you need. [The keys](#the-keys) lists them.
5. Save and close the file.

For example:

```sh
GITHUB_TOKEN="ghp_..."
CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
GIT_AUTHOR_NAME="Your Name"
GIT_AUTHOR_EMAIL="you@example.com"
```

Inside the double quotes, write `\\`, `\"`, `` \` `` and `\$` for a literal backslash, quote, backtick and dollar sign. The installer reads the file with the parser in `lib/system/envfile.sh`, never with `source`, and rewrites it with every key in a fixed order. A value you wrote stays.

If you pass a token on the command line anyway, start the command with a space. In bash with `HISTCONTROL=ignoreboth`, the Debian default, a line that starts with a space stays out of the history. devaloy's zsh config does not set `HIST_IGNORE_SPACE`, so in zsh run `setopt HIST_IGNORE_SPACE` first. The installer never prints a value.

## 2. Run the installer

As `boxuser`, not with `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-upstash.sh | bash
```

The installer calls `sudo -n` itself for the root steps. It prints a numbered heading for each step:

1. Preflight: not root, an Upstash Box on the Node runtime, `sudo -n`, `/workspace/devaloy` and `/workspace/.devaloy` (made with `sudo` when missing, because `/workspace` belongs to root), the OS and architecture, and a route to `github.com`.
2. The repo: it clones devaloy to `/workspace/devaloy`, owned by `boxuser`.
3. The env file: it merges your variables into `/workspace/.devaloy/env`.
4. The boot: it runs `lib/steps/upstash-boot.sh` in the foreground and streams its log. A cold toolchain install takes several minutes.
5. The SDK step: it sets the init command and opens the public URL.
6. Done: it prints the preview URL, the first pairing link and the next steps.

The command exits 0 only after the boot succeeds. On a new `aarch64` Upstash Box with a `GITHUB_TOKEN`, the cold install took 58 s.

A non-empty variable on the command line overwrites the value in the env file. An empty or missing one keeps it. To install a branch or a tag, put the ref in the URL and in `DEVALOY_REF`:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/<ref>/scripts/install-upstash.sh | DEVALOY_REF=<ref> bash
```

Re-running the one-liner is safe. A second run with the same inputs changes no file under `/workspace` apart from logs, `boot-status` and the toolchain's own state. A re-run is also how you change `DEVALOY_REF` or a `WITH_*` key.

### The keys

The env file holds these keys. Each one means what [Reference](reference.md#environment-variables) says, with the differences in the third column.

| Group | Keys | On an Upstash Box |
|---|---|---|
| Tailnet | `WITH_TAILSCALE`, `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_ACCEPT_DNS` | Tailscale is optional and off by default. `TS_HOSTNAME` defaults to the box's Upstash name (`UPSTASH_BOX_NAME`) and is also the T3 environment label. See [Optional Tailscale](#optional-tailscale). |
| GitHub and git | `GITHUB_TOKEN`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_SIGNING_SSH_KEY`, `DEVALOY_REPOS` | The boot clones `DEVALOY_REPOS` into `/workspace/home`. |
| Agents and services | `CLAUDE_CODE_OAUTH_TOKEN`, `CLOUDFLARE_API_TOKEN`, `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET` | Written to `~/.devaloy_secrets` on every boot. A cleared value is gone after the next boot. |
| Push notifications | `NTFY_TOPIC`, `NTFY_SERVER`, `NTFY_TOKEN` | See [Push notifications](push-notifications.md). |
| Features | `WITH_BROWSER`, `DEVALOY_SLIM` | `true` or `false`, default `false`. See [Disk](#disk). |
| Toolchain and source | `MISE_NODE_VERSION`, `DEVALOY_REF` | `DEVALOY_REF` defaults to `main`. |
| Home | `UPSTASH_HOME_MODE` | `move` (default) or `links`. See [Logs and files](#logs-and-files). |
| Fixed on this runtime | `WITH_T3CODE`, `WITH_DOCKER`, `WITH_PASEO`, `RUNTIME` | Always `true`, `false`, `false` and `upstash`. The installer and the boot ignore what the file says. |

`UPSTASH_BOX_API_KEY` is never a key in the file. A key you add by hand stays in the file across re-runs.

To change a value later, edit the file and run the boot:

```sh
bash /workspace/devaloy/lib/steps/upstash-boot.sh
```

## 3. Give the installer the API key

At step 5 the installer asks:

```
  Upstash API key (empty to skip):
```

The input does not echo. You can also pass the key as `UPSTASH_BOX_API_KEY` (with a leading space, see [step 1](#1-write-the-env-file-first)). The installer installs `@upstash/box` into a temp directory and runs one Node script with the key in its environment. The script sets the init command to `bash /workspace/devaloy/lib/steps/upstash-boot.sh --detach` and opens the public URL for port 3773. The key goes to that one process only, never to the env file, a log or the terminal, and the temp directory is deleted after the call.

### No key, or the SDK call fails

With an empty answer, no terminal, or an SDK error, the installer goes on and prints the two steps to do by hand:

```
  Do these two steps in the Upstash console instead:

    1. Box <box-id> > Init command:
         bash /workspace/devaloy/lib/steps/upstash-boot.sh --detach
    2. Box <box-id> > Public URLs: expose port 3773.

  Or run this again with the key: install-upstash.sh --sdk-only
```

Do both in the Upstash console, or run the SDK step again with the key:

```sh
bash /workspace/devaloy/scripts/install-upstash.sh --sdk-only
```

Without the init command, the server does not come back after a pause.

## 4. Pair the phone

The server listens on `0.0.0.0:3773`. The phone reaches it through the preview URL:

```
https://<box-id>-3773.preview.box.upstash.com
```

The installer prints the first pairing link at the end. For a new link, run on the box:

```sh
t3-pair
```

`t3-pair` runs `t3 pair` and rewrites every link it prints to the preview URL. It prints a `Pairing URL:` line and an `App link:` line, and no QR code, because `t3 pair` encodes the container address in the QR code. Open the app link on the phone, or paste the pairing URL in the app under **Settings → Environments → Add environment**. Each link works once, so run `t3-pair` again for each new device. The boot writes `t3-pair` to `~/.local/bin` on every start.

**The pairing token is the only lock.** The preview URL has no Upstash bearer token or basic auth, because the T3 Code apps cannot send them. Anyone with the URL reaches the server, and only a valid pairing token gets a session. Port 3773 is also open on the Upstash internal network. Revoke a device you no longer use; see [Revoke a device](connect-the-t3-code-apps.md#revoke-a-device).

## 5. Sign in the agents

The installer runs no sign-in flow.

**Claude Code.** Put `CLAUDE_CODE_OAUTH_TOKEN` in `/workspace/.devaloy/env`, as on every devaloy box. Make the token on a machine with a browser:

```sh
claude setup-token
```

Then run the boot so it writes the token to `~/.devaloy_secrets`:

```sh
bash /workspace/devaloy/lib/steps/upstash-boot.sh
```

**Codex.** Sign in once on the box, with a ChatGPT Plus or Pro plan:

```sh
codex login --device-auth
```

It prints a URL and a code. Open the URL on your laptop or phone and enter the code. `~/.codex` is on `/workspace`, so the login survives a pause, and Codex refreshes it itself. A reset wipes it, so sign in again after one. For API billing, use `codex login --with-api-key` instead. Never copy `~/.codex/auth.json` from another machine. Sign in on each box with its own login.

## 6. Pick the thread-title provider

T3 Code names each new thread with a provider, and the default is Codex. Either sign in to Codex as in [step 5](#5-sign-in-the-agents), or switch the title provider to Claude in the T3 Code app's settings.

## Pause and resume

A pause keeps the filesystem and kills every process. On resume, Upstash runs the init command again. The boot finds the overlay already in place, skips the downloads, and starts the T3 server loop again.

The first request after a resume can get a short 502 while the server starts. On a real Upstash Box, the preview URL answered 200 about 7 s after the resume, after one 503. With Tailscale on, it took about 45 s.

A request to the preview URL wakes a paused box, so the phone app wakes it when you open it.

## Reset

A reset wipes the whole box, `/workspace` included: the clone, `/workspace/.devaloy/env` with your tokens, the toolchain, your repos and worktrees, T3's threads and pairings, and any work you did not push. Only the box id, the init command and the public URL survive. The init command then finds no clone and fails, and the preview URL answers 502.

**Do not reset a devaloy box.** On the one box we reset, the container came back with root's capabilities dropped (`CapEff 00000000200000c0`: no `CAP_CHOWN`), so `sudo` could not chown or install anything, and the one-liner could not run again. After a pause, the SDK's `resume()` then failed with HTTP 500. The installer's preflight checks for this and stops with a message.

To start over, delete the box and create a new one, then run the one-liner on it. Push your work first, and take a snapshot when you want to keep the box as it is.

## Snapshot restore

A box made from a snapshot gets `/workspace` but not the init command or the public URL. Set them on the new box, then run the boot once:

1. Run the SDK step with your API key:
   ```sh
   bash /workspace/devaloy/scripts/install-upstash.sh --sdk-only
   ```
2. Start the boot:
   ```sh
   bash /workspace/devaloy/lib/steps/upstash-boot.sh
   ```

Re-running the one-liner does both steps in one command. Pair the phone again, because the preview URL carries the new box ID.

## Optional Tailscale

Tailscale gives the box a tailnet name for SSH and for `devaloy fleet`. The T3 apps do not need it. Turn it on with these keys:

```sh
WITH_TAILSCALE="true"
TS_AUTHKEY="tskey-auth-..."
```

Then run the boot, or re-run the one-liner. With `WITH_TAILSCALE=true` and no key in the file, the installer asks for one on the terminal. Use a reusable, untagged key; see [step 4 of Getting started](getting-started.md#4-set-an-auth-key).

The box has no `/dev/net/tun`, so `tailscaled` runs with `--tun=userspace-networking`. Its state is in `/workspace/.devaloy/tailscale`, so the node keeps its name through a pause. A reset wipes it, and the node joins as a new device. Tailscale SSH works in this mode.

If your tailnet has device approval on, a new node waits in the admin console under **Machines** until you approve it, and the boot log says so. Approve it there and it joins by itself, with no new key. A pre-approved key skips the wait. The box blocks UDP, so tailnet traffic goes through a DERP relay; on the first real box that added about 230 ms.

The boot also adds a user `dev` with the same uid as `boxuser` and the home `/workspace/home`. The tailnet policy rule from [step 3 of Getting started](getting-started.md#3-add-an-ssh-rule-to-your-tailnet-policy-file) allows the user `dev`, so this works with no policy change:

```sh
ssh dev@<TS_HOSTNAME>
```

A paused box is off the tailnet, and Tailscale traffic does not wake it. `devaloy fleet` shows a paused box as down. Set `WITH_TAILSCALE="false"` and run the boot to stop `tailscaled` again.

## Disk

`/workspace` is 10G, and it holds everything that lasts: the home, the toolchain, the repos and the caches. On a real `aarch64` Upstash Box, the full toolchain in `~/.local/share/mise` took 1.7G, and all of `/workspace` took 3.1G after the install. Of that, `~/.cache` was 712M and `~/.t3` was 420M. That leaves about 7G for repos and worktrees.

`DEVALOY_SLIM="true"` leaves out `neovim`, `tree-sitter`, `wrangler`, `cf` and `infisical`, and skips the LazyVim seed. The default is `false`. Set it when you need the space, then run the boot.

`devaloy doctor` warns when `/workspace` has less than 1G free. Run `devaloy clean` to see what it can remove.

## Manage the box

The `devaloy` CLI works as on any other box:

- `devaloy doctor` checks `boot-status`, the T3 server on port 3773, the init command path, `tailscaled` when `WITH_TAILSCALE` is on, and the free space on `/workspace`. It has no systemd or Docker rows.
- `devaloy status` shows the disk of `/workspace`.
- `devaloy update` pulls `/workspace/devaloy`, reinstalls the CLI with `install-upstash.sh --cli-only`, updates the toolchain, and restarts the T3 server loop so a new `t3` takes over. The restart cancels running turns.

To restart the T3 server by hand:

```sh
bash /workspace/devaloy/lib/steps/upstash-serve.sh t3 restart
```

## Logs and files

| Path | What it is |
|---|---|
| `/workspace/devaloy` | The repo, cloned at `DEVALOY_REF`, owned by `boxuser`. `/opt/devaloy` links to it. |
| `/workspace/.devaloy/env` | Every setting and token. `boxuser` only, mode 0600. |
| `/workspace/.devaloy/logs/boot.log` | The log of the last boot. The boot before it is `boot.log.1`. |
| `/workspace/.devaloy/logs/t3.log` | The T3 server loop. |
| `/workspace/.devaloy/logs/tailscaled.log` | The `tailscaled` loop, with `WITH_TAILSCALE=true`. |
| `/workspace/.devaloy/boot-status` | `ok <time>` after a good boot, or `failed <step> <time>`. |
| `/workspace/.devaloy/run/` | The pidfiles of the two loops (`t3.pid`, `tailscaled.pid`) and the boot lock. |
| `/workspace/.devaloy/tailscale/` | The Tailscale node state. |
| `/workspace/home` | The home of `boxuser`: the toolchain, `~/.claude`, `~/.codex`, `~/.t3`, repos and worktrees. |

The boot sets the passwd home of `boxuser` to `/workspace/home` on every start, so every dotfile lands on the persistent disk. `/home/boxuser` and its Upstash links stay as they are. If the home move breaks Upstash SSH or the runner on your box, set `UPSTASH_HOME_MODE="links"`: the home then stays `/home/boxuser`, and the boot links a fixed list of names in it into `/workspace/home`.

When a boot fails, read `boot-status` for the step, then `boot.log` for the error. Fix the cause and run the boot again.

## What this runtime does not have

- Docker. `WITH_DOCKER` is fixed to `false`.
- Paseo. `WITH_PASEO` is fixed to `false`.
- systemd. The init command and the two loops in `upstash-serve.sh` do its work.
- Kernel-mode Tailscale. Only userspace networking, and only when you turn it on.
- The host firewall lockdown. There is no `--lockdown` flag.
- Other Upstash runtimes. Only the Node runtime.
- Backups. Push to a remote, as on every devaloy box.

_Written from the code on 2026-11-11 and checked in a look-alike container on `x86_64` (`scripts/upstash-lookalike.sh`). Not yet verified on a real Upstash Box._
