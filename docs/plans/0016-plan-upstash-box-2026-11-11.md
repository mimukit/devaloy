# Plan: devaloy on an Upstash Box

Grilled: 2026-11-11

## Context

An Upstash Box is a cheap, pausable container that Upstash hosts. It can be a T3 Code remote environment that the phone reaches with no VPS to run. On one box (smiling-molly-74011, 2026-11-11) a hand setup works: `t3` from npm in `/workspace/home/.local`, a `t3-start` script that the Upstash init command runs, a public preview URL for port 3773, and a `t3-pair` helper that prints the preview pairing link. Pause and resume through the SDK bring the server back.

devaloy cannot install there today. `scripts/install-native.sh` wants Ubuntu 24.04 or Debian 13, systemd and `/dev/net/tun`. The box is Debian 12 bookworm on aarch64, PID 1 is `docker-init`, and there is no tun. The user is `boxuser` (uid 1002), not `dev`. Only `/workspace` (xfs, 10G) is persistent storage. The handoff said it survives a reset; Phase 7 showed a reset wipes it too. Pause keeps the filesystem but kills every process. The hand setup also has none of the devaloy layers: no mise toolchain, no skills, no Claude and Codex config seed, no git identity, no repo clones, no ntfy, no `devaloy` CLI.

Goal: one command turns a fresh Upstash Box into a devaloy box that runs T3 Code, as close to a native VM as the box allows, and the box keeps working through pause and resume with no second command. A reset wipes the whole box, `/workspace` included (found in Phase 7), so after a reset the one-liner is the way back. Decision by the user, 2026-11-11: reset means reinstall, with no self-healing init command and no tokens stored in Upstash box env.

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-upstash.sh | bash
```

Success outcome:

- On a fresh Upstash Box (Node runtime), that command exits 0 only after the toolchain is ready and the T3 server listens on 3773.
- The T3 phone app pairs through `https://<box-id>-3773.preview.box.upstash.com`.
- After an SDK pause and resume, the preview URL answers 200 with no human action.
- After a reset, the one-liner run again brings the box back, and the URL answers 200 again.
- A second run of the installer exits 0 and changes no file under `/workspace` apart from logs and the toolchain stamp.

Target: open, no baseline. Phase 7 measures the cold install time, the resume-to-200 time and the reset-to-200 time, and records them here. The numbers do not gate a phase.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Reuse | A third runtime, `RUNTIME=upstash`, beside `container` and `native`. The installer calls `lib/system/` and `lib/steps/`, and `bootstrap-toolchain.sh` with `config/mise/`. Only the work that this runtime alone does goes in new files, per AGENTS.md. User pick, 2026-11-11. |
| Entry point | `scripts/install-upstash.sh`, run as `boxuser` with `curl ... \| bash` (not `sudo bash`). It calls `sudo -n` for the root steps. Same output shape and idempotence contract as `install-native.sh`. |
| Home | The boot sets the passwd home of `boxuser` to `/workspace/home` on every container start (`usermod -d`, no move). `DEV_USER=boxuser`, `DEV_HOME=/workspace/home`. Every dotfile, `~/.config/mise`, `~/.local/bin/mise`, `~/.claude.json` and `~/.gitconfig` then lives on the persistent disk with no link list. `/home/boxuser` and its Upstash links stay as they are. User pick, 2026-11-11. Phase 1 checks that Upstash SSH and the runner accept it. |
| Repo clone | `/workspace/devaloy`. The boot links `/opt/devaloy -> /workspace/devaloy` on every start, so every hardcoded `/opt/devaloy` path (`CONFIG_SRC`, `build-flags`, `runtime-flags`, `config_src()`) works with no edit. |
| Supervisor | No systemd. The Upstash init command is the boot unit. It runs once per container start (create, resume, snapshot restore) as `boxuser` from `/workspace/home`. Its value is `bash /workspace/devaloy/lib/steps/upstash-boot.sh --detach`, a path on the persistent disk, because `/usr/local/lib/devaloy` is gone after a reset. `--detach` starts the boot with `setsid` and exits 0 at once, so it does not matter whether Upstash waits on the init command or has a timeout. The installer runs the same boot in the foreground. Grill Q6. |
| Boot order | `upstash-boot.sh` re-execs itself as root with `sudo -n`, then: (1) converge the overlay: the `/opt/devaloy` link, `usermod -d /workspace/home -s /usr/bin/zsh boxuser`, `config/apt/packages.txt` minus `tailscale` unless it is on, `zsh-completions`, the CLI, `build-flags` with `RUNTIME=upstash`; (2) the same `lib/steps/` calls as `native_boot`, minus Docker and Paseo; (3) start the T3 serve loop and, when on, `tailscaled`, both detached with `setsid`. `apt_ensure` is a no-op on resume, so the overlay work costs time only after a reset. |
| Process restart | A serve loop, the twin of the container's T3 loop: `while :; do t3 serve ...; sleep 10; done` under `setsid nohup`, guarded by a check for a listener on `:3773` (not `pgrep -f`, which matched its own ssh command line in the hand setup). Log to `/workspace/.devaloy/logs/t3.log`. |
| T3 bind | `--host 0.0.0.0 --port 3773 --no-browser`, `T3CODE_TELEMETRY_ENABLED=false T3CODE_SERVER_BROWSER_SANDBOX=0`, the same `env -i` login environment as `native-serve.sh`. The preview proxy needs the container address, so the tailnet-IP bind of `native-serve.sh` does not apply. The T3 pairing token is the lock; the preview URL has no Upstash auth. |
| Network | The Upstash preview URL is the T3 route: it is tested, and a request to it wakes a paused box. Tailscale is optional (`WITH_TAILSCALE=true` plus `TS_AUTHKEY`), in userspace mode (`tailscaled --tun=userspace-networking`), with its state in `/workspace/.devaloy/tailscale`. It gives `ssh boxuser@<name>` and the fleet a route while the box is awake. User pick, 2026-11-11. |
| SDK caller | The installer, on the box. It reads `UPSTASH_BOX_API_KEY` from the environment or from a silent `/dev/tty` prompt, installs `@upstash/box@0.7.10` into a temp dir, and runs one Node script that calls `Box.get(UPSTASH_BOX_ID)`, `setInitCommand`, and `getPublicURL(3773)`. The key goes to that child process only and never to disk. With no key and no tty, the installer prints the two console steps. A `--sdk-only` flag re-runs this step after a snapshot restore. User pick, 2026-11-11. |
| Env file | `/workspace/.devaloy/env`, mode 600, owner `boxuser`, the same systemd-style grammar as `/etc/devaloy/env`. Same merge rule as `install-native.sh`: a non-empty variable overwrites, an empty one keeps the stored value. `read_env_file` and the merge move from `install-native.sh` into `lib/system/envfile.sh`, so both installers share one parser. The boot reads the file with that parser, never with `source`. `UPSTASH_BOX_API_KEY` is never a key in it. |
| Keys | `TS_AUTHKEY TS_HOSTNAME TS_ACCEPT_DNS WITH_TAILSCALE GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLOUDFLARE_API_TOKEN INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET DEVALOY_REPOS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_SIGNING_SSH_KEY NTFY_TOPIC NTFY_SERVER NTFY_TOKEN WITH_BROWSER MISE_NODE_VERSION DEVALOY_REF`. `WITH_T3CODE=true` is fixed. `WITH_DOCKER` and `WITH_PASEO` are fixed to false. |
| Environment label | `TS_HOSTNAME` when set, else `UPSTASH_BOX_NAME`, written to `/etc/machine-info` by `step_t3code_label` on every start. |
| Agent CLIs | mise manages `claude` and `codex` as on every devaloy box, so the versions match the fleet and `devaloy update` moves them. The Upstash copies in `/opt/runner/bin` stay for the Upstash runner. The T3 server finds the mise copies first through the `/usr/local/bin` mirror that `link-shims` keeps. |
| Pairing | A `t3-pair` script in `~/.local/bin` (installed by the boot, not by `config/bin/`, because only this runtime needs it). It runs `t3 pair "$@"` and rewrites the printed host to `https://${UPSTASH_BOX_ID}-3773.preview.box.upstash.com`. The installer prints its first link at the end. |
| Git identity | Ours wins. With `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` set through the installer merge, the boot wrote them to `~/.gitconfig`, and after an SDK pause and resume `git config --global user.name` still gave `devaloy test`. Upstash wrote nothing on that resume: the mtime of `/workspace/home/.gitconfig` and of `/home/boxuser/.gitconfig` did not change. With both keys cleared and the identity removed from `~/.gitconfig`, a second pause and resume left the box with no identity at all, so Upstash does not put its own back on a resume. | An empty value in the merge keeps the stored one, so the two keys were cleared with `sed` in `/workspace/.devaloy/env` on the box, and the Upstash default `Upstash Box <box@upstash.com>` was set back by hand. The boot warning that commits carry the Upstash identity is wrong when `~/.gitconfig` has none. |
| Resume to tailnet | 45 s from the first preview request to a 200 from `http://100.77.115.101:3773/` over the tailnet, and 48 s to a 200 on the preview URL. The first preview request timed out at 20 s, then 503 until 47 s. `boot-status` was `ok` at 41 s, the boot log has `Tailscale SSH is up as devaloy-box-new`, and `devaloy doctor` over Tailscale SSH exited 0. | This cycle started from an SDK pause with Tailscale on; the cycles without Tailscale gave 7 s, apart from the first at 32 s. |
| Agent auth | No auth flow in the script. `CLAUDE_CODE_OAUTH_TOKEN` goes through the env file, as on every box. Codex needs one `codex login --device-auth` on the box (Plus or Pro); `~/.codex` is on the persistent disk, so it refreshes itself. The wiki page names both, and the T3 thread-title provider. |
| Home fallback | If Phase 1 shows that the home move breaks Upstash SSH or the runner, the passwd home stays `/home/boxuser` and the boot keeps a fixed symlink list into `/workspace/home`: `.config .local/bin .gitconfig .claude.json .zshrc .zshenv .t3 projects worktrees .devaloy_env .devaloy_secrets`. A new `write_through` helper in `lib/steps/common.sh` writes into the link target when the destination is a symlink; `commit_staged` and `step_claude_onboarding` use it. It is a no-op on the other runtimes. Grill Q1, Q17. |
| Disk | Rule: if the full toolset plus 4G of space for repos does not fit in `/workspace`, the box runs slim. A shared `DEVALOY_SLIM` key makes `bootstrap-toolchain.sh` delete the `neovim`, `tree-sitter`, `npm:wrangler`, `npm:cf` and `infisical` lines from the staged config before the hash, so the key moves the marker. The key goes in `runtime-flags`. The installer's default on upstash comes from the Phase 1 measurement; the env file can override it. `doctor` warns under 1G free on `/workspace`. Grill Q2, Q15, Q16. |
| Fleet | When `WITH_TAILSCALE=true` and Phase 1 shows it works, the boot adds a same-uid user on every start: `useradd -o -u 1002 -g 1002 -d /workspace/home -s /usr/bin/zsh dev`. `ssh dev@<name>` and `devaloy fleet` then work with no change to `lib/fleet.sh`. A paused box shows as down in the fleet. If the test fails, fleet is a non-goal. Grill Q3, Q18. |
| Preview auth | The T3 pairing token is the only lock. No Upstash `bearerToken` or basic auth, because the T3 apps cannot send them. The wiki says so, and says that port 3773 is also open on the Upstash internal network. Grill Q4. |
| Runtimes | Node runtime only. The preflight refuses any other `UPSTASH_BOX_RUNTIME` with a message. Grill Q7. |
| Clone owner | `/workspace/devaloy` belongs to `boxuser`. Grill Q8. |
| Browser | `WITH_BROWSER` stays a key, default false. Grill Q9. |
| Secrets on the command line | The wiki tells the user to write `/workspace/.devaloy/env` first, or to start the command with a space so it stays out of shell history. The installer never echoes a value. Grill Q22. |
| Outward actions | None beyond commits on the plan's branch: no push, no issues, no deploy. The user creates and deletes Upstash Boxes. Grill Q14. |
| Tests | No new test runner. Phases 2 to 5 run in a local look-alike (amd64; this box is `x86_64` and the Upstash Box is `aarch64`, so arch checks stay in Phase 7): a `debian:12` container on this box with a `boxuser` (uid 1002, passwordless sudo), a `/workspace` volume and PID 1 `tail -f /dev/null`, started with no extra caps. The script that builds it lives in `scripts/upstash-lookalike.sh`, so the checks can run again. shellcheck covers every changed shell file. |

## Approach

The installer and the boot follow the native path step for step. `install-upstash.sh` is the twin of `install-native.sh`, and `upstash-boot.sh` is the twin of `native-boot.sh`. They reuse `lib/system/common.sh` (`put_file`, `apt_ensure`), `lib/system/steps.sh` (`sys_base_packages`, `sys_zsh_completions`, `sys_install_cli`, `sys_build_flags`), every step in `lib/steps/env.sh`, `git.sh`, `toolchain.sh`, `t3code.sh`, and `step_tailscale_ensure` from `tailscale.sh`. What is new is only what this runtime does: the overlay converge after a reset, the home move, the SDK call, the detached serve loop, userspace `tailscaled`, and `t3-pair`.

Rejected alternatives, one line each:

- A standalone script that only codes the hand setup. Smallest diff, but no toolchain, skills or config seed, and it drifts from devaloy on the first change.
- A symlink list in `/home/boxuser` in place of the home move. Every step that replaces a file with `mv` (`commit_staged`, the `~/.claude.json` merge) turns a link into an overlay file, which a reset then loses.
- Tailscale as the only route. A paused box does not wake from tailnet traffic, so the phone loses the box after one idle hour on the free plan.

### Phase 1: spike on a real box (built 2026-11-11)
Attended: the user creates a new free Upstash Box and enters the Upstash API key through `request_secret` (file delivery). An agent on devaloy then runs the spike over SSH (`SSH_ASKPASS`, since this box has no `sshpass`) and the SDK, and deletes the key file at the end. The agent deletes no box. Grill Q5, Q19, Q20.

Answer each question on the real box and record the results in a table in this plan:

1. After `sudo usermod -d /workspace/home boxuser`, does `ssh <box-id>@us-east-1.box.upstash.com` land with `HOME=/workspace/home`? Does the Upstash runner still start Claude and Codex? If not, the Home fallback row applies.
2. What are `PATH`, `HOME` and the cwd in the init command?
3. Does `tailscaled --tun=userspace-networking` run, does Tailscale SSH accept a login as `boxuser`, and does a tailnet peer reach `:3773`? Does tailnet traffic stop the idle pause?
4. How much of the 10G on `/workspace` does the full `config/mise/config.toml` toolchain take on aarch64 (`du -sh ~/.local/share/mise`)? Apply the Disk rule to set the installer's `DEVALOY_SLIM` default.
5. Does a same-uid `dev` user let `ssh dev@<name>` work over Tailscale SSH? Apply the Fleet row.

Done when: the plan holds a results table with an answer to each of the five questions, and the Home fallback, Disk and Fleet rows each name the branch the result picked.

#### Phase 1 results (2026-11-11, box actual-porpoise-84497)

| Item | Answer | Evidence |
|------|--------|----------|
| Q1 home move | Yes. A new Upstash SSH session lands with `HOME=/workspace/home` and cwd `/workspace/home`, and `getent passwd boxuser` gives `/workspace/home:/usr/bin/zsh`. Upstash SSH still starts bash, not the passwd shell. The runner still works: `box.exec.command` runs as boxuser with `HOME=/workspace/home`, and `/opt/runner/bin/claude --version` (2.1.293) and `codex --version` (0.159.2) answer. No agent run was started. | The T3 server's own PATH puts the mise installs first (claude 2.1.322, codex 0.167.1). A non-interactive `ssh <box> cmd` gets no mise PATH, because `/workspace/home` has no `.profile`, so `claude` there is the runner copy. An interactive session gets the mise shims first. |
| Q2 init env | Runs as boxuser (uid 1002) through `sh /workspace/home/.box/startup.sh`, cwd `/workspace/home`, umask 0022. `HOME=/workspace/home` (from passwd), `LANG=C.UTF-8`, `UPSTASH_BOX_ID` set, `PATH=/opt/runner/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/boxuser/.local/bin:/home/boxuser/.cargo/bin:/home/boxuser/go/bin:/workspace/home/node_modules/.bin`. No `USER`, `LOGNAME` or `SHELL`. | Probe init command, then SDK pause and resume. `install-upstash.sh --sdk-only` on the box set `bash /workspace/devaloy/lib/steps/upstash-boot.sh --detach`; `getInitCommand()` and `getPublicURL(3773)` from devaloy confirm it, with no bearer token and no basic auth. |
| Q3 Tailscale | Yes, after one admin approval. `tailscaled --tun=userspace-networking` runs, and the installer with `WITH_TAILSCALE=true` and a `TS_AUTHKEY` exits 0 and logs in. This tailnet needs an admin to approve each new device, so the node sat in `NeedsMachineAuth` until the user approved it in the admin console; tailscaled then joined by itself with no new key. The node is `devaloy-box-new` (`devaloy-box-new.tail31a6dd.ts.net`, 100.77.115.101). A peer reaches `:3773`: `curl http://100.77.115.101:3773/` from devaloy-ovh gives 200. Tailscale SSH accepts `boxuser@devaloy-box-new` with no password. Tailnet traffic does not wake a paused box: `tailscale ping` gets no reply, the curl gives no answer, and the SDK status stays `paused`; devaloy-ovh shows the node offline within 36 s of the pause. Whether tailnet traffic resets the idle timer stays unknown. | UDP is blocked on the box, so every path goes through the DERP relay `iad` (about 230 ms). `tailscale ping` then prints a pong but exits 1 with `direct connection not established`. The SDK `BoxData.last_activity_at` advances every 30 s while the box runs, with or without a session, and stops while it is paused, so it cannot tell tailnet traffic from other activity. While the node waits for approval, every boot spends about 110 s in `tailscale up` and the name wait before it starts the T3 server. |
| Q4 disk | The full toolset fits. On aarch64, `~/.local/share/mise` is 1.7G, `~/.cache` 712M, `~/.t3` 420M, and `/workspace` 3.1G in total, with 7.0G free of 10G. | 3.1G plus 4G is 7.1G, under 10G. |
| Q5 same-uid dev user | Yes. `ssh dev@devaloy-box-new` over Tailscale SSH lands with `HOME=/workspace/home`, uid 1002 (`id` prints the name `boxuser`, the first passwd entry for the uid), `SHELL=/usr/bin/zsh`, and `claude` from the mise shims (2.1.322). `ssh boxuser@devaloy-box-new` gives the same. The tailnet policy refused neither user. `devaloy fleet list`, `fleet status` and `fleet doctor` from devaloy-ovh find the box and run on it with no change to `lib/fleet.sh`; doctor there exits 0 with the tailscaled and tailscale rows ok. | `fleet list` labels the box runtime `container`, because its probe maps every value but `native` to `container`, and `CLONE` says `no clone` because the box keeps its clone at `/workspace/devaloy`, not `~/projects/devaloy`. `fleet status` prints the container hostname, not the box name. `fleet update` was not run. |
| Install time | 61 s wall for `install-upstash.sh --no-sdk` (mise: 16 tools in 21.9 s). | The run exited 1 at the toolchain: `neovim` got HTTP 403 from the GitHub API, which was at 0 of 60 anonymous calls on the box's shared egress IP. The next boot installed it and wrote `ok`. The first run, before a fix, died in the preflight because `/workspace` is `root:root 0711`. |
| Resume to 200 | 7 s after an SDK pause, in two cycles (503 at 4 s, then 200). The first cycle took 32 s, with a curl timeout of 15 s on the first request. | A request to the preview URL wakes the box. After the resume `boot-status` was `ok` and `devaloy doctor` exited 0. |
| Home fallback row | Not needed. The home move stays (`UPSTASH_HOME_MODE=move`). | Q1. |
| Disk row | `DEVALOY_SLIM` default `false`, as in `scripts/install-upstash.sh`. | Q4. |
| Fleet row | Fleet works: the boot keeps adding the same-uid `dev` user when `WITH_TAILSCALE=true`, and `devaloy fleet` reaches the box with no change to `lib/fleet.sh`. A paused box shows as offline. | Q3 and Q5. The runtime label in `fleet list` is a small follow-up fix. |
| Pairing | `t3-pair` prints the pairing URL and the app link on `https://actual-porpoise-84497-3773.preview.box.upstash.com`. `/pair` and `/` answer 200 through the preview URL. | The `Token:` line of `t3 pair` passes through unchanged. |

### Phase 2: the shared layer takes a third runtime (built 2026-11-11)
- `lib/steps/common.sh`: `DEV_USER="${DEV_USER:-dev}"` and `DEV_HOME="${DEV_HOME:-/home/${DEV_USER}}"`. Add `on_upstash()` beside `on_native()`; anything else still reads as container. `LOG_TAG=devaloy` on upstash too. Recovery hints that name `systemctl` or `docker compose exec` get an upstash branch that names the init command and the log file.
- `lib/common.sh`: `devaloy_runtime` returns `upstash` for `RUNTIME=upstash`; add `on_upstash()`.
- `lib/system/install.sh` and `sys_build_flags`: accept `RUNTIME=upstash`.
- New `lib/system/envfile.sh`: `read_env_file`, the key merge and the writer, moved from `install-native.sh` with no change in behavior. `install-native.sh` sources it. The key list stays with each installer.
- `link-shims` already reads `DEV_HOME`; check that nothing else in `lib/` assumes `/home/dev` on the boot path.
- `bootstrap-toolchain.sh`: the `DEVALOY_SLIM` key from the Disk row, read like `WITH_PASEO` (environment, then `runtime-flags`). `step_runtime_flags` records it.
- `lib/steps/common.sh`: the `write_through` helper from the Home fallback row.

Done when: shellcheck passes on every changed file; a round-trip script reads a sample env file with quotes, `$`, backticks and a newline through the old and the new `read_env_file`, and the two outputs are byte-equal; with `DEV_USER` unset, sourcing `lib/steps/common.sh` gives `DEV_USER=dev` and `DEV_HOME=/home/dev`, and with `DEV_USER=boxuser DEV_HOME=/workspace/home` it gives those values; `bootstrap-toolchain.sh` with `DEVALOY_SLIM=true` stages a config with none of the five slim lines and a different marker hash than with the key off.

### Phase 3: the boot and the serve loop (built 2026-11-11)
- New `lib/steps/upstash-boot.sh`: re-exec as root with `sudo -n`; read `/workspace/.devaloy/env` with `read_env_file` and export its keys; converge the overlay (see the Boot order row); run the `native_boot` step list minus Docker and Paseo, with `DEV_USER=boxuser DEV_HOME=/workspace/home RUNTIME=upstash`; write `/workspace/.devaloy/boot-status` (`ok` or the failed step, plus a timestamp) for `doctor`; start the serve loop and, when on, `tailscaled`. Log to `/workspace/.devaloy/logs/boot.log`.
- New `lib/steps/upstash-serve.sh`: `t3` runs the serve loop from the T3 bind row, with the `:3773` listener guard; `tailscaled` starts userspace `tailscaled` with its state dir on `/workspace` and the socket at `TS_SOCKET`, then the boot calls `step_tailscale_ensure`.
- `t3-pair`, written to `~/.local/bin` by the boot.
- `scripts/upstash-lookalike.sh`: start or stop the look-alike container from the Tests row.

Done when: in the look-alike, with `/workspace/devaloy` copied in and `WITH_TAILSCALE=false`, `bash /workspace/devaloy/lib/steps/upstash-boot.sh` as `boxuser` exits 0, `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3773/` prints `200`, and a second run starts no second server (one listener on `:3773`).

### Phase 4: the installer (built 2026-11-11)
`scripts/install-upstash.sh`, in the order of `install-native.sh`:

1. preflight: run as non-root `boxuser`, `UPSTASH_BOX_ID` set, `sudo -n true` works, `/workspace` writable, Debian 12 or newer, x86_64 or aarch64, a route to `github.com`;
2. clone or move `/workspace/devaloy` to `DEVALOY_REF` (default `main`), with the same fetch and checkout logic;
3. merge `/workspace/.devaloy/env`;
4. run `upstash-boot.sh` in the foreground and stream its log until the toolchain is ready;
5. the SDK step (see the SDK caller row), skipped with `--no-sdk`;
6. print the preview URL, the first `t3-pair` link, and the next steps (Codex sign-in, the title provider).

Flags: `--cli-only` (for `devaloy update`), `--sdk-only`, `--no-sdk`.

Done when: in the look-alike, `bash scripts/install-upstash.sh --no-sdk` exits 0 from a clean `/workspace`; a second run exits 0, and `find /workspace -newer <stamp> -type f` lists only logs, `boot-status` and the toolchain stamp.

### Phase 5: the CLI on this runtime (built 2026-11-11)
- `devaloy doctor` on upstash: rows for `boot-status`, a listener on `:3773`, `tailscaled` when `WITH_TAILSCALE` is on, the init command file path present, free space on `/workspace` (warn under 1G); no systemd or Docker rows.
- `devaloy status`: disk is `/workspace`, not `/home/dev`.
- `devaloy update` on upstash: pull `/workspace/devaloy`, run `install-upstash.sh --cli-only`, then restart the serve loop so a new `t3` takes over.

Done when: in the look-alike, `devaloy doctor` exits 0 with the `t3 server` row ok; after the server is killed, it exits non-zero and names the row; `devaloy update` exits 0 and the `:3773` listener has a new PID.

### Phase 6: docs (built 2026-11-11)
- `docs/wiki/install-on-an-upstash-box.md`: before you start, the one command, the API-key prompt, the console fallback, pairing, Claude token and Codex device sign-in, the T3 title provider, pause and resume, reset, snapshot restore (`--sdk-only`), disk limits, and what this runtime does not have.
- Links from `docs/wiki/index.md`, `docs/wiki/reference.md` (the env file keys and paths) and `README.md`. A line in `docs/wiki/architecture.md` on the third runtime.

Done when: the page exists, the index links to it, and every command and flag in the page resolves to a line in `scripts/install-upstash.sh` or `lib/` (checked with grep).

### Phase 7: end to end on a fresh box
Attended: the user creates a new free Upstash Box, enters the API key through `request_secret`, and pairs the phone (step 2). The agent runs steps 1, 3, 4 and 5. It is last because it checks the built work. Grill Q13, Q20, Q21.

1. Run the one command on a fresh box with the key at the prompt. Record the time to exit 0.
2. Pair the phone through the printed link, and start a Claude thread.
3. Pause and resume through the SDK. Record the time until the preview URL answers 200.
4. Reset: skipped by the user, 2026-11-11. On box needed-tortoise-40254 a console reset wiped `/workspace`, and the new container ran with root's capabilities dropped (`CapEff 00000000200000c0`, no `CAP_CHOWN`), so no reinstall could run; after a pause, `resume()` returned HTTP 500. The wiki now says not to reset a devaloy box, and the preflight stops on a root that cannot chown. Steps 3 and 5 run on a new box instead.
5. Run the command again and check that it is converged.

Done when: steps 1, 2, 3 and 5 pass on a new box, and the cold install time and the resume-to-200 time are written into the Target line of Context. The first request after a resume may return a short 502; the wiki states the measured wait (grill Q12).

## Part 2: Tailscale by default, with a wake step (added 2026-11-11)

### Context

Every other devaloy box is reached over Tailscale: `ssh dev@<name>`, `devaloy fleet`, and `wtforward` on the laptop, which picks an SSH host alias from `~/.ssh/config` and holds one ControlMaster connection to it. Part 1 made Tailscale optional on an Upstash Box because a paused box runs no `tailscaled` and tailnet traffic cannot wake it (Phase 1: ping and curl to the tailnet IP got nothing, and the SDK status stayed `paused`). Only a request to the preview URL or the SDK's `resume()` wakes it. The user wants Tailscale as the default anyway, so every tool works the same on every box, with a wake step that runs before a client needs the tailnet.

Goal: `ssh dev@<name>`, `wtforward <alias>` and `devaloy fleet status` reach an Upstash Box that has paused, with no manual wake.

Target: open, no baseline beyond Phase 1b (tailnet 200 at 45 s after a resume, which included a device-approval wait that is now fixed). Phase 8 measures the time from a wake request to a tailnet SSH login, and Phase 13 the time from `ssh` on a paused box to a shell prompt.

### Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Tailscale default | On. `WITH_TAILSCALE` defaults to true on this runtime; `WITH_TAILSCALE="false"` turns it off. User pick, 2026-11-11. |
| Wake mechanism | A request to the preview URL `https://<box-id>-3773.preview.box.upstash.com/`, which is public and needs no secret, then a wait until the tailnet node answers. User pick, 2026-11-11. |
| Box id lookup | One mapping file, `~/.config/devaloy/upstash-boxes`, one `<tailnet-name> <box-id>` line per box, on every machine that connects (the laptop, devaloy-ovh). The user adds each line by hand; the installer prints the exact line at the end. Grill Q23, Q32. |
| Wake script | `upwake`, a POSIX `sh` script in `config/bin/`, so `step_seed_config` puts it in `~/.local/bin` on every box; the laptop gets it with `scp`, as with `wtforward`. `upwake <host>` exits 0 at once when the host is not in the mapping file. Otherwise it checks `nc -z -w 2 <host> 22` and returns at once when the host answers; otherwise it prints `waking <name> …` to stderr, requests the preview URL, and waits up to 90 s for port 22, then exits non-zero with the preview URL. Grill Q27, Q28, Q29. |
| SSH config | One line at the top of `~/.ssh/config`: `Match exec "upwake %h"`. `ssh`, `scp`, `git` over SSH and `wtforward` all read it. A host that is not in the mapping file (GitHub, for example) costs one `grep`. Grill Q33. |
| Fleet | `devaloy fleet list` never wakes: a paused Upstash Box shows `paused` and the hint `upwake <name>`, from `tailscale status` and the mapping file. `status`, `doctor` and `update` run `upwake` on each offline box in the mapping file first. Grill Q24, Q38. |
| No `TS_AUTHKEY` | The installer asks on the terminal, as for the API key. With no terminal, it installs with Tailscale off and prints a warning naming the two env-file lines to add. Grill Q25. |
| Pause during use | Accepted. A pause drops open SSH sessions and `wtforward`, and `upwake` wakes the box on the next connection. No keeper loop and no SDK `keepAlive`. `wtforward` is not changed; the wiki says to start it again. User pick, grill Q26, Q34. |
| Tailscale key | Reusable, pre-approved, untagged, not ephemeral. An ephemeral node is removed on each pause, and an unapproved node blocked Phase 1b. The wiki says so. Grill Q31. |
| Tests | Phases 9 to 12 run in the look-alike, with an `UPWAKE_URL_BASE` override that points `upwake` at a local HTTP stub, since the look-alike has no preview proxy. The real pause and wake are tested in the attended Phases 8 and 13. Grill Q36. |
| Outward actions | None beyond commits on `main`. The user creates the boxes and the keys. Grill Q39. |

### Approach

Reuse: `scripts/wtforward` is the model for a laptop-side POSIX `sh` script; `config/bin/` is seeded into `~/.local/bin` on every box by `step_seed_config`; `lib/fleet.sh` already lists boxes from `tailscale status --json` and probes them over `ssh dev@<ip>`; Part 1's `step_tailscale_ensure` (with the `NeedsMachineAuth` fix), `upstash-serve.sh tailscaled` and the same-uid `dev` user stay as they are.

Rejected, one line each: the box id in a per-box SSH snippet (one snippet per box, and fleet still needs a file); the tailnet name as the box id (unreadable names and T3 labels); a keeper loop or SDK `keepAlive` (the user accepts the pause).

### Phase 8: spike the wake path on a real box
Attended: needs an Upstash Box with Tailscale on, the API key, and a pre-approved reusable `TS_AUTHKEY`. Grill Q30: the user's new box, after the fresh-agent run.
Measure: the time from a preview URL request on a paused box to a tailnet SSH login, three times; whether an open tailnet SSH session stops the idle pause (for the wiki only, grill Q35).
Done when: the plan holds a results table with the times and the answer.

### Phase 9: Tailscale on by default in the installer and the boot
- `WITH_TAILSCALE` defaults to true in `scripts/install-upstash.sh` and `lib/steps/upstash-boot.sh`.
- The `TS_AUTHKEY` prompt and the no-terminal fallback from the No `TS_AUTHKEY` row.
- The installer's last screen prints the mapping line `<tailnet-name> <box-id>` and the SSH config line.
Done when: in the look-alike, the installer with no `WITH_TAILSCALE` in the env file and a key in the environment starts `tailscaled`; with `WITH_TAILSCALE="false"` it does not; with no key and no terminal it exits 0 with Tailscale off and the warning; the last screen shows the mapping line.

### Phase 10: the wake script
`config/bin/upwake`, per the Wake script row, with `UPWAKE_URL_BASE` and `UPWAKE_MAP` overrides for tests.
Done when: shellcheck passes; against a local HTTP stub in the look-alike, `upwake` for an unlisted host exits 0 in under 0.1 s, for a listed host that answers exits 0 in under 2 s with no request to the stub, and for a listed host that does not answer requests the stub once and exits non-zero after the timeout (shortened by an override) with the preview URL in its message.

### Phase 11: fleet wakes Upstash boxes
`lib/fleet.sh` per the Fleet row.
Done when: with a saved `tailscale status --json` (`DEVALOY_FLEET_STATUS_JSON`) that marks one mapped node offline, `fleet list` shows it as `paused` with the hint and makes no request, and `fleet status` calls `upwake` for it (checked with a stub `upwake` on `PATH`).

### Phase 12: docs
The wiki's Optional Tailscale section becomes Tailscale: the default, the key kind, the mapping file, `upwake` on the laptop, the SSH config line, `wtforward` after a pause, and fleet. `docs/wiki/reference.md` lists `upwake` and the mapping file.
Done when: every command, path and key in the new text resolves to a line in the repo.

### Phase 13: end to end from the laptop
Attended: needs the laptop, a paused Upstash Box with Tailscale on, and the mapping file and SSH line set up as the wiki says.
1. Pause the box. `ssh dev@<name>` from the laptop: record the time to a prompt.
2. Pause the box. Start `wtforward <alias>`: it connects and forwards a port.
3. Pause the box. `devaloy fleet list` on devaloy-ovh shows it `paused`; `devaloy fleet status` wakes it and reports it up.
Done when: steps 1 to 3 pass, and the step 1 time is written into the Part 2 Target line.

## Open questions

All grill decisions are settled. Phase 1 picks a branch for three of them (Home fallback, Disk, Fleet); the rule for each branch is in the design table. These facts stay open until a phase measures them:

- Does tailnet traffic count as activity for the Upstash idle pause? Phase 8 measures it. It changes only the wiki text.
- The cold install time, the resume-to-200 time and the reset-to-200 time. Phase 7.

## Non-goals

- Docker, Paseo, systemd units, the host firewall lockdown and Sysbox. The box cannot run them, or they add nothing here.
- Creating, listing or deleting Upstash Boxes. The script sets up the box it runs on.
- Kernel-mode Tailscale.
- Keeping a box awake while it is in use (keeper loop or SDK `keepAlive`), and an automatic reconnect in `wtforward`. Part 2 accepts the pause.
- Sharing one Codex `auth.json` between machines, or any Codex sign-in flow inside the script.
- Python and other non-Node Upstash runtimes.
- `t3 browser setup` with sudo. `T3CODE_SERVER_BROWSER_SANDBOX=0` covers the warning, as on a VM.
- Backups of `/workspace`. Push to a remote, as on every devaloy box.
