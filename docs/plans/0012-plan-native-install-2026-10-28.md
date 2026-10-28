# Plan: Native install on an Ubuntu VM

Grilled: 2026-10-28

## Context

Today devaloy only runs as a Docker Compose container. A user with a plain Ubuntu VM has to install Docker first, load `tun`, and sometimes install Sysbox before they get a shell. Some VMs (cheap VPS plans, a VM inside a nested hypervisor, a corporate image with no Docker allowed) make that path heavy or impossible, and the container adds nothing on a VM that serves only devaloy.

The goal is a box you can reach the same way (`ssh dev@devaloy` over Tailscale SSH, same toolchain, same `devaloy` CLI) on a VM that never had Docker, set up with one command:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo TS_AUTHKEY=tskey-auth-... bash
```

To install a branch or a tag, put the ref in both places:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/feat/native-install/scripts/install-native.sh | sudo DEVALOY_REF=feat/native-install TS_AUTHKEY=tskey-auth-... bash
```

Success outcome: on a fresh Ubuntu 24.04 VM, that one command with no file edits exits 0 only after the toolchain is ready, the node answers `ssh dev@devaloy`, and `devaloy doctor` exits 0. A second run of the same command exits 0 and changes no file under `/etc`, `/opt/devaloy` or `/home/dev` apart from the toolchain stamp and logs it already owns.

Target: open, no baseline. Phase 3 measures the time from the command to exit 0 on the test VM and records it here. The number does not gate a phase.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Runtime | Native. No container, no Docker requirement. devaloy runs directly on the VM. |
| Entry point | A new `scripts/install-native.sh`, run as `curl ... \| sudo bash`, same shape as `scripts/setup-sysbox-host.sh`. |
| Which code installs | `DEVALOY_REF`, default `main`. The installer clones that ref to `/opt/devaloy` and checks it out. No checksum: a checksum served from the same repo protects nothing the TLS fetch does not. |
| Wait for the toolchain | The one-liner waits and streams progress. It exits 0 only after `Toolchain ready`. `--no-wait` returns once Tailscale SSH is up and leaves the bootstrap to `devaloy-boot.service`. |
| Secrets input | Read `TS_AUTHKEY` and the optional tokens from the environment. Prompt on `/dev/tty` for `TS_AUTHKEY` only, and only when it is missing from both the environment and `/etc/devaloy/env`. With no tty either, fail and print the exact command to re-run. Optional tokens come from the environment, or from an edit of `/etc/devaloy/env` followed by `sudo systemctl restart devaloy-boot`. |
| Env versus file precedence | A non-empty environment variable overwrites the value in `/etc/devaloy/env`. An empty or unset variable leaves the file value. To clear a token, edit the file. |
| Secrets storage | `/etc/devaloy/env`, owned by root, mode 0600, same variable names as `.env.example`. It replaces `.env` on a native box. `devaloy-boot.service` still writes `~/.devaloy_secrets` for `dev` on every boot, so the file protects the tokens from nothing that runs as `dev`. |
| Repo location | `/opt/devaloy`, root-owned. `CONFIG_SRC` stays `/opt/devaloy/config`, the path the container uses today. |
| Shared logic | Split `entrypoint.sh` into step functions under `lib/steps/`. The container entrypoint and the native installer call the same functions. No second copy of the setup logic. |
| Process supervision | systemd. tailscaled uses the unit the `tailscale` package ships. Paseo and T3 Code get `devaloy-paseo.service` and `devaloy-t3code.service` with `Restart=always`. Per-boot work runs in a `devaloy-boot.service` oneshot. The `while true` restart loops in `entrypoint.sh` stay container-only. |
| OOM order | Keep the container's ladder through `OOMScoreAdjust=`: tailscaled -500; dockerd, Paseo, T3 Code -250; user sessions 0. |
| `TS_ACCEPT_DNS` natively | Defaults to true. The false default exists to protect Docker's resolver inside a container, and that reason does not apply on a VM. The container default stays false. |
| Failed `tailscale up` | The installer exits non-zero, leaves sshd open, and prints `sudo tailscale up --ssh --hostname=<name>`. `--lockdown` never runs after a failure. Public sshd and the `ubuntu` user are the recovery route. |
| Optional features in v1 | `WITH_DOCKER`, `WITH_BROWSER`, `WITH_T3CODE`, `WITH_PASEO`. |
| `WITH_DOCKER` natively | Install Docker Engine from Docker's apt repo on the VM, add `dev` to the `docker` group. No Sysbox, no nested daemon. Off by default, so a VM with no Docker keeps no Docker. |
| Docker address ranges | Apply `config/docker/daemon.json`. Keep its `10.201.0.1/16` bridge and `10.202.0.0/16` pool when both are free on the VM. Otherwise pick free `10.x/16` ranges with the probe from `scripts/setup-sysbox-host.sh`, moved into a shared function. |
| Re-runs | Idempotent. A re-run converges the VM to `DEVALOY_REF`: `git fetch` and checkout in `/opt/devaloy`, then every step again. Each step checks before it writes. |
| `devaloy update` natively | `reexec_as_dev` (`lib/common.sh`) already drops it to `dev`, so it runs `sudo git -C /opt/devaloy pull --ff-only`, reinstalls the CLI and `lib/`, then runs the existing seed and toolchain bootstrap. |
| Supported OS | Ubuntu 24.04 only. The installer reads `/etc/os-release` and refuses any other release. |
| Users | Create `dev` with the next free UID and zsh as login shell. Keep the cloud image's `ubuntu` user as the provider console recovery route. |
| sudo | `dev` keeps passwordless sudo, as in the container. The docs state that the VM must serve nothing else and is disposable. |
| Public sshd | Left alone by default. `--lockdown` runs `scripts/host-firewall-lockdown.sh` after the installer proves Tailscale SSH is up. Its anti-lockout guards stay as they are. |
| Flag files | The installer writes `/opt/devaloy/build-flags` (the role the Dockerfile has today) and adds `RUNTIME=native`. `devaloy-boot.service` writes `/opt/devaloy/runtime-flags` from `/etc/devaloy/env` on every boot. `devaloy doctor` and `devaloy health` read `RUNTIME` to choose the checks. |
| apt package list | Move the package list out of the Dockerfile into `config/apt/packages.txt`. The Dockerfile and the installer both read it, so the two lists cannot drift. |
| Test approach | No new test runner. Phase 1 builds the image before and after the change on this box's nested Docker, runs each with no `TS_AUTHKEY` (`tailscale up` fails without stopping the container, and the seed still runs), and diffs the seeded `/home/dev`. When the nested run cannot start, that check moves to an attended run on the OVH host. Phases 3 to 5 check on a throwaway VM with the commands in each `Done when:`. |
| Lint | `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable` on every new or changed script. The box toolset does not change for it. |
| Test VM | A throwaway Ubuntu 24.04 VM with `TS_HOSTNAME=devaloy-vmtest`, so it cannot collide with the live `devaloy-ovh` node. A person runs the first install. The agent runs every later check and re-run as `ssh dev@devaloy-vmtest sudo ...`. |
| Outward actions | The build may push the feature branch `feat/native-install` to `origin`. No push to `main`, no force-push. The test VM installs from that branch through `DEVALOY_REF`. |
| PR shape | One PR for all six phases. |

## Approach

The installer is thin. It does the work that the Dockerfile does at build time (apt packages, Tailscale repo, `dev` user, CLI install, flag files), then hands over to the same step functions the container entrypoint calls at boot. The per-boot steps (rewrite `~/.devaloy_secrets`, seed config, git identity, signing, repo clones) run again on every VM boot through `devaloy-boot.service`, so clearing a value in `/etc/devaloy/env` and rebooting revokes it, the same contract `.env` plus a redeploy gives today.

It reuses, unchanged in behaviour:

- `bootstrap-toolchain.sh` for mise and the whole toolchain, run as `dev`.
- `link-shims` for the `/usr/local/bin` mirror.
- `lib/update.sh` (`do_config_seed`, `config_src`) for the dotfile seed.
- `lib/common.sh` (`BUILD_FLAGS_FILE`, `RUNTIME_FLAGS_FILE`, `reexec_as_dev`) for the flag files and the drop to `dev`.
- `scripts/host-firewall-lockdown.sh` for `--lockdown`.
- `scripts/setup-sysbox-host.sh` for the free `10.x` range probe, and as the style model: `set -euo pipefail`, a usage block, refusal on a piped stdin that cannot prompt.

Rejected alternatives, one line each:

- A separate native script that copies the logic. Fastest to write, but `entrypoint.sh` changes often and the copy would drift within weeks.
- Run `entrypoint.sh` itself as a systemd service with native guards. Least new code, but it keeps the `&` plus `wait` process model inside a unit, so systemd cannot restart Paseo or T3 Code on its own.

### Phase 1: Split entrypoint.sh into step functions

Move each `# --- ... ---` section of `entrypoint.sh` into a function in `lib/steps/` (for example `step_shell_env`, `step_secrets`, `step_push_config`, `step_seed_config`, `step_tailscale_up`, `step_toolchain`, `step_gh_auth`, `step_git_identity`, `step_signing`, `step_clone_repos`, `step_paseo_config`, `step_t3code_config`). Each function takes its inputs from the environment and writes only files. Process start (tailscaled, dockerd, Paseo, T3 Code) stays in `entrypoint.sh` for the container. `entrypoint.sh` becomes a list of calls plus the container-only process blocks. The Dockerfile copies `lib/steps/` with the rest of `lib/`.

The working tree has uncommitted edits to `devaloy` and `lib/common.sh` (the `kp` work). Start this phase after those land.

Done when: images built from `main` and from the branch, each run with the same `.env` minus `TS_AUTHKEY` on a fresh volume until `Toolchain ready`, give the same output for `find /home/dev -type f -not -path '*/.cache/*' -not -path '*/.local/share/mise/*' -print0 | sort -z | xargs -0 sha256sum`; both logs print `devaloy is up`; `devaloy doctor` exits 0 in the branch image; shellcheck is clean on `entrypoint.sh` and `lib/steps/*.sh`.

### Phase 2: Make the steps host-agnostic

Remove the container assumptions the steps carry: paths under `/var/run` and `/var/log` that the container owns, the `docker compose exec` recovery hints, and the probes that assume PID 1 is the entrypoint. Add `RUNTIME` (`container` or `native`) to `/opt/devaloy/build-flags`. Teach `devaloy health` to check `systemctl is-active` for the native units, and `devaloy doctor` to report the runtime. Move the apt package list to `config/apt/packages.txt` and make the Dockerfile read it. Move the free-range probe out of `scripts/setup-sysbox-host.sh` into a shared function that both scripts call.

Done when: the Phase 1 diff still matches, `devaloy doctor` prints `runtime: container` in the container, `DEVALOY_LIB=./lib RUNTIME=native ./devaloy doctor` on a plain shell prints `runtime: native` and names the missing units instead of failing on missing Docker paths, and `scripts/setup-sysbox-host.sh --help` still prints its usage.

### Phase 3: The core installer

Attended: a person provisions a throwaway Ubuntu 24.04 VM, makes a reusable untagged test auth key, and runs the first one-liner on it with `DEVALOY_REF=feat/native-install TS_HOSTNAME=devaloy-vmtest`. The build pushes `feat/native-install` before this step. Every later check in Phases 3 to 5 runs from the agent over `ssh dev@devaloy-vmtest`.

Write `scripts/install-native.sh`. In order:

1. Preflight: root, Ubuntu 24.04, `x86_64` or `aarch64`, `/dev/net/tun` present (load `tun` when it is missing), network to GitHub and `pkgs.tailscale.com`.
2. Collect secrets with the precedence in Design decisions. Write `/etc/devaloy/env` at 0600.
3. Install apt packages from `config/apt/packages.txt` and the Tailscale apt repo.
4. Create `dev` (next free UID, zsh, passwordless sudo drop-in) when it does not exist.
5. Clone `/opt/devaloy` at `DEVALOY_REF`, or fetch and check out that ref when the clone exists. Install `devaloy`, `lib/`, `bootstrap-toolchain.sh` and `link-shims` to the paths the Dockerfile uses, plus the five legacy symlinks.
6. Write `/opt/devaloy/build-flags`.
7. Enable `tailscaled.service` and run `step_tailscale_up`. On failure, follow the failed `tailscale up` row and exit non-zero.
8. Install and enable `devaloy-boot.service` (oneshot, `After=tailscaled.service network-online.target`, `EnvironmentFile=/etc/devaloy/env`) and start it. It runs the per-boot steps and then the toolchain bootstrap as `dev`.
9. Without `--no-wait`, follow `journalctl -u devaloy-boot` until the unit finishes, and exit with its result.
10. Print the same final line as the container: `devaloy is up. Connect with: ssh dev@<hostname>`.

Done when: on the test VM the one-liner exits 0, `ssh dev@devaloy-vmtest 'devaloy doctor'` exits 0, `sudo reboot` followed by the same `ssh` works with no manual step, a run with `--no-wait` returns before `Toolchain ready` appears in `journalctl -u devaloy-boot`, and the measured install time is recorded in Context.

### Phase 4: Optional features

Add the four flags, read with the same precedence as the secrets:

- `WITH_DOCKER=true`: add Docker's apt repo, install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` and `docker-compose-plugin`, add `dev` to `docker`, apply `config/docker/daemon.json` with the range rule from Design decisions, set `OOMScoreAdjust=-250` through a drop-in.
- `WITH_BROWSER=true`: install the Chromium libraries the Dockerfile installs today, and let `bootstrap-toolchain.sh` fetch `playwright-cli` and Chromium as it does now. The sandbox probe in the browser step runs unchanged; natively it is expected to pass.
- `WITH_PASEO=true` and `WITH_T3CODE=true`: install `devaloy-paseo.service` and `devaloy-t3code.service` (`User=dev`, `Restart=always`, `RestartSec=10`, `OOMScoreAdjust=-250`, bind to the tailnet IP the same way the entrypoint does). Turning a flag off disables and stops its unit on the next run.

Done when: on the test VM with all four flags on, `docker run --rm hello-world` works as `dev` with no sudo, `docker network inspect bridge` shows a subnet that no route in `ip route` overlaps, `playwright-cli open https://example.com` followed by a screenshot writes a PNG, `systemctl is-active devaloy-paseo devaloy-t3code` prints `active` twice, and `journalctl -u devaloy-t3code` shows the pairing link. With the flags set back to false and the installer re-run, both units are inactive and `devaloy doctor` still exits 0.

### Phase 5: Idempotent re-run and native update

Make every installer step check before it writes. Make `devaloy update` detect `RUNTIME=native` and run `sudo git -C /opt/devaloy pull --ff-only` before the seed and the bootstrap. Add `--lockdown`: after step 7 proves `tailscale ip -4` answers, run `scripts/host-firewall-lockdown.sh`, with its guards.

Done when: a second run of the one-liner on the Phase 4 VM exits 0 and `find /etc /opt/devaloy /home/dev -newer <stamp> -type f` lists only the toolchain stamp and logs; `devaloy update` on the VM pulls a new commit pushed to the branch and the next `devaloy -h` shows it; `--lockdown` run from a public-IP SSH session refuses, and run over the tailnet enables `ufw` with only `tailscale0` allowed in.

### Phase 6: Docs

Add `docs/wiki/install-on-a-vm.md` (the one-liner, `DEVALOY_REF`, `--no-wait`, `--lockdown`, the env variables, how to revoke a token, how to recover through the provider console). Add the native rows to `docs/wiki/reference.md` and a line in `docs/wiki/index.md` and the README front door. State in the page that the VM must serve nothing else, because `dev` has passwordless sudo and agents run in bypass mode on the VM itself.

Done when: every command in `docs/wiki/install-on-a-vm.md` appears in the installer or the CLI (checked with `grep`), and the one-liner exactly as the page prints it, with `DEVALOY_REF=feat/native-install`, re-run on the test VM exits 0 with `devaloy doctor` exiting 0.

## Open questions

None. The draft's eight questions are settled in Design decisions or moved to Non-goals.

## Non-goals

- Any OS other than Ubuntu 24.04, including 22.04, Debian and macOS.
- Sysbox or a nested Docker daemon on the native path.
- An uninstall path. A disposable VM is rebuilt instead.
- Release tags or a checksum for the one-liner.
- Moving an existing container home volume onto a native VM. `docs/wiki/migrate-to-a-new-host.md` covers the container case only.
- A VM that serves other workloads. The native path assumes a disposable, single-purpose VM.
- Changing the container path's behaviour. Phase 1 and Phase 2 are refactors for it, and their `Done when:` lines prove no change.
