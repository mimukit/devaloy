# Install on a VM

devaloy also runs straight on an Ubuntu 24.04 VM, with no Docker and no container. One command turns a fresh VM into the same box: `ssh dev@devaloy` over Tailscale SSH, the same toolchain in `/home/dev`, the same `devaloy` CLI. systemd does the supervising that `entrypoint.sh` does in the container, and the per-boot work runs from the same step functions in `lib/steps/`.

Use this path when the VM exists only for devaloy, or when Docker is heavy or impossible there: a small VPS plan, a VM inside a nested hypervisor, a corporate image with no Docker allowed. Use the container ([Getting started](getting-started.md)) when the host also runs other things, or when you want a redeploy to throw away everything outside the home volume.

**The VM must serve nothing else.** `dev` has passwordless sudo, and the agents on the box run in bypass permission mode on the VM itself, not inside a container. Anything else on that VM, its files, its services, its credentials, is in reach of every agent session. Treat the VM as disposable: there is no uninstall, and the way to remove devaloy is to rebuild the VM.

## Before you start

You need:

- A fresh Ubuntu 24.04 VM, `x86_64` or `aarch64`, booted with systemd. The installer refuses any other release.
- `/dev/net/tun`. The installer runs `modprobe tun` when it is missing. If that fails, turn on TUN in the VM's settings at the provider.
- Outbound HTTPS to `github.com` and `pkgs.tailscale.com`.
- A login with sudo, usually the cloud image's `ubuntu` user over public SSH, and access to the provider's console. The installer leaves both alone, and they are your way back in if Tailscale does not come up.
- The SSH rule in your tailnet policy file. See [step 3 of Getting started](getting-started.md#3-add-an-ssh-rule-to-your-tailnet-policy-file).
- A reusable, untagged Tailscale auth key. See [step 4 of Getting started](getting-started.md#4-set-an-auth-key). An untagged key is what lets the `autogroup:self` rule match.

## 1. Run the installer

Log in to the VM as the `ubuntu` user and run:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo TS_AUTHKEY=tskey-auth-... bash
```

The installer prints a numbered heading for each step: preflight, the clone to `/opt/devaloy`, `/etc/devaloy/env`, the apt packages, the `dev` user, the CLI, `build-flags`, Tailscale SSH, the systemd units, and `devaloy-boot`. It then streams the `devaloy-boot` log until the boot steps and the toolchain bootstrap finish. A cold toolchain install takes several minutes. The last line is:

```
devaloy is up. Connect with: ssh dev@devaloy
```

The command exits 0 only after `devaloy-boot` succeeds. It exits non-zero when any step fails, and says which one.

Put every variable after `sudo`, on the same line, as above. `sudo` resets the environment, so a variable you `export` in your shell first never reaches the installer.

If you leave out `TS_AUTHKEY`, the installer asks for it on the terminal. With no terminal to ask on, it stops and prints the command to re-run with the key.

### Install a branch or a tag

`DEVALOY_REF` picks the branch or tag the installer clones. The default is `main`. Put the ref in the URL and in the variable, so the script you run comes from the same ref it installs:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm TS_AUTHKEY=tskey-auth-... bash
```

The installer stores the ref in `/etc/devaloy/env`, so a later re-run with no `DEVALOY_REF` stays on that ref. Set `DEVALOY_REF=main` to move back. A tag checks out detached, and `devaloy update` does not pull a tag.

### Turn on optional features

Each feature is a variable on the same line. All four default to `false`, and each takes only `true` or `false`.

| Variable | On a VM |
|---|---|
| `WITH_DOCKER` | Installs Docker Engine from Docker's apt repo and adds `dev` to the `docker` group. Writes `/etc/docker/daemon.json` with the repo's address ranges, or with free `10.x/16` ranges when the repo's overlap the VM's own network. No Sysbox and no nested daemon. Setting it back to `false` leaves Docker installed and running. |
| `WITH_BROWSER` | Installs the headless Chromium libraries from `config/apt/browser.txt`. The bootstrap then fetches `playwright-cli` and Chromium into the home directory. |
| `WITH_PASEO` | Enables `devaloy-paseo.service`, the Paseo daemon on `<tailnet-ip>:6767`. See [Connect the Paseo apps](connect-the-paseo-apps.md). |
| `WITH_T3CODE` | Enables `devaloy-t3code.service`, the T3 Code server on `<tailnet-ip>:3773`. The pairing link is in `journalctl -u devaloy-t3code`. See [Connect the T3 Code apps](connect-the-t3-code-apps.md). |

For example:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo TS_AUTHKEY=tskey-auth-... WITH_DOCKER=true WITH_T3CODE=true bash
```

To change a feature later, re-run the one-liner with the new value. Setting `WITH_PASEO=false` or `WITH_T3CODE=false` disables and stops that unit.

### Other variables

The installer also reads `TS_HOSTNAME` (the tailnet name, default `devaloy`) and every `.env` variable that means something on a VM: `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLOUDFLARE_API_TOKEN`, `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`, `DEVALOY_REPOS`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_SIGNING_SSH_KEY`, `NTFY_TOPIC`, `NTFY_SERVER`, `NTFY_TOKEN`, `WITH_PASEO_WEB_UI`, `PASEO_PASSWORD`, `PASEO_PLUGINS`, `TS_ACCEPT_DNS` and `MISE_NODE_VERSION`. Each one means what [Reference](reference.md#environment-variables) says, with one difference: `TS_ACCEPT_DNS` defaults to `true` on a VM, because there is no Docker resolver to protect. Set `TS_ACCEPT_DNS=false` to turn MagicDNS off on the box.

A non-empty variable on the command line overwrites the value stored in `/etc/devaloy/env`. An empty or missing one keeps the stored value. So you pass a token once, and a re-run without it keeps it. You can also skip the command line and edit the file; see [Change or revoke a token](#change-or-revoke-a-token).

The compose-only variables (`DEVALOY_NAME`, `DEVALOY_RUNTIME`, `DEVALOY_PRIVILEGED`, the `DEVALOY_*` resource ceilings, `DEVALOY_SHM_SIZE`) have no meaning on a VM and the installer ignores them.

### Return before the toolchain finishes

`--no-wait` returns as soon as Tailscale SSH is up, and leaves the toolchain bootstrap running in `devaloy-boot.service`. A flag goes after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --no-wait
```

Follow the rest of the boot with:

```sh
journalctl -fu devaloy-boot
```

## 2. Disable key expiry on the node

Turn off key expiry on the new node in the [admin console](https://login.tailscale.com/admin/machines), as in [step 7 of Getting started](getting-started.md#7-disable-key-expiry-on-the-node). An expired node drops off the tailnet, and on a VM the way back is public SSH or the provider console.

## 3. Log in

From any device on your tailnet:

```sh
ssh dev@devaloy
```

Then check the box:

```sh
devaloy doctor
```

It prints `runtime: native` under the date, and one row each for `tailscaled`, `devaloy-boot`, and the Docker, Paseo and T3 Code units when their flag is on. It exits 0 when everything that is on works.

## Lock down public SSH

The installer leaves the VM's own sshd and firewall alone. `--lockdown` closes them: after Tailscale SSH is up, it runs `scripts/host-firewall-lockdown.sh`, which sets `ufw` to deny every inbound connection except on `tailscale0`. See [Lock down the host firewall](lock-down-the-host-firewall.md) for the rules it writes.

Run it from an SSH session over the tailnet, not from the public IP:

```sh
ssh dev@devaloy
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo bash -s -- --lockdown
```

The re-run needs no `TS_AUTHKEY`, because the node is already on the tailnet. `--lockdown` refuses, and changes nothing, in these cases:

- `tailscale ip -4` does not answer.
- Your SSH session comes from an address outside `100.64.0.0/10`, for example the VM's public IP.
- The installer cannot find your SSH session at all. `sudo` strips `SSH_CONNECTION`, so the installer looks for it in the processes above it. From the provider console there is none.

From the provider console, and only when you are sure the tailnet works, override the last two with `ALLOW_NON_TAILNET=1`:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo ALLOW_NON_TAILNET=1 bash -s -- --lockdown
```

A refusal does not undo the install. When `ufw` already denies incoming traffic except on `tailscale0`, `--lockdown` prints `already locked down` and does nothing.

After the lockdown, the tailnet is the only network way in. If Tailscale breaks, the provider console is the only way back, and `sudo ufw disable` there opens public SSH again.

## Where things live

| Path | What it is |
|---|---|
| `/opt/devaloy` | The repo, cloned at `DEVALOY_REF`, owned by root. |
| `/opt/devaloy/build-flags` | `WITH_DOCKER`, `WITH_BROWSER` and `RUNTIME=native`. Written by the installer. |
| `/opt/devaloy/runtime-flags` | The `WITH_*` keys, rewritten by `devaloy-boot` on every boot. |
| `/etc/devaloy/env` | Every setting and token. Root only, mode 0600. The VM's counterpart of `.env`. |
| `/usr/local/bin/devaloy`, `/usr/local/lib/devaloy/` | The CLI and its modules, `lib/steps/` included. |
| `/etc/systemd/system/devaloy-boot.service` | The per-boot oneshot: shell env, secrets, dotfiles, Tailscale check, toolchain, git, Paseo and T3 Code config. Runs `/usr/local/lib/devaloy/steps/native-boot.sh` as root. |
| `/etc/systemd/system/devaloy-paseo.service`, `devaloy-t3code.service` | The two servers, as `dev`, with `Restart=always`. Always installed; enabled only when their flag is on. |
| `/etc/systemd/system/tailscaled.service.d/devaloy-oom.conf` | `OOMScoreAdjust=-500` for `tailscaled`, the last process the kernel should kill. |
| `/etc/systemd/system/docker.service.d/devaloy-oom.conf` | `OOMScoreAdjust=-250` for `dockerd`, with `WITH_DOCKER=true`. |
| `/etc/docker/daemon.json` | Docker's address ranges. Owned by the installer on a VM, not copied on each boot. |
| `/etc/sudoers.d/dev` | Passwordless sudo for `dev`. |
| `/home/dev` | The home directory, with the toolchain, repos and credentials. A plain directory, not a volume. |

The boot log is in the journal, with each line prefixed `[devaloy]`:

```sh
journalctl -u devaloy-boot
```

`systemctl status devaloy-boot` shows `active (exited)` after a good boot. The server logs are in `journalctl -u devaloy-paseo` and `journalctl -u devaloy-t3code`.

## Change or revoke a token

Edit `/etc/devaloy/env`, then restart the boot unit:

```sh
sudo systemctl restart devaloy-boot
```

The boot rewrites `~/.devaloy_secrets`, the `gh` login, the push config and the signing key from the file, so a cleared value is gone after the restart. If you changed a value the Paseo daemon or the T3 Code server reads, restart that unit too:

```sh
sudo systemctl restart devaloy-boot devaloy-paseo
```

Keep the double quotes the installer writes. Inside them, write `\\`, `\"`, `` \` `` and `\$` for a literal backslash, quote, backtick and dollar sign. The file's header comment says the same.

To clear a value you must edit the file. An empty variable on the installer's command line keeps the stored value.

`TS_AUTHKEY` matters only while the node is not on the tailnet. To revoke the key itself, revoke it in the Tailscale admin console.

## Update the box

Run, as `dev`:

```sh
devaloy update
```

On a VM it first runs `sudo git -C /opt/devaloy pull --ff-only` and reinstalls the CLI and `lib/` from `/opt/devaloy`, then seeds the config and re-runs the toolchain bootstrap, as in the container. `devaloy update --no-config` skips the pull. On a tag, the pull is skipped with a message.

`devaloy update` does not reinstall the systemd unit files or the apt packages. For a change to those, re-run the one-liner.

## Re-run the installer

Re-running the one-liner is safe. Every step checks before it writes, so a second run with the same inputs changes no file under `/etc`, `/opt/devaloy` or `/home/dev` apart from the toolchain's own state and logs. A re-run is also how you change `DEVALOY_REF` or a `WITH_*` flag, and how you pick up a changed unit file.

## When `tailscale up` fails

The installer stops at the Tailscale step, exits non-zero and prints:

```
sudo tailscale up --ssh --hostname=devaloy
```

The installer did not touch sshd or the firewall, so the SSH session you ran it from still works. If that session is gone, log in as `ubuntu` over public SSH, or use the provider console. The installer keeps the `ubuntu` user for this.

Then either:

- fix the key or the policy file and re-run the one-liner with a new `TS_AUTHKEY`, or
- run the printed `sudo tailscale up` command, finish the login it asks for, and re-run the one-liner. With the node on the tailnet, the installer does not ask for a key.

The usual causes are a used one-off key, an expired key, or a tagged key. A node that joins but refuses `dev` is missing the policy rule. [Recover a box you cannot reach](recover-an-unreachable-box.md) lists these causes for the container; the fixes on the Tailscale side are the same.

## Remove devaloy

There is no uninstall. Rebuild the VM from a fresh image, and remove the old node from the [admin console](https://login.tailscale.com/admin/machines).

_Verified against `issue-4-install-devaloy-natively-on-an-ubuntu-vm` on 2026-10-28, from the code. The VM steps are not yet verified on a real VM._
