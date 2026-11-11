# Plan: fleet management for devaloy boxes

Grilled: 2026-11-11

## Context

The owner runs devaloy on two boxes today, `devaloy-ovh` (container) and `devaloy-insta` (native, found at build time). More boxes will follow. Each box has the `devaloy` CLI, but nothing runs a verb on all boxes, and no list of boxes exists. An agent such as Claude Code must find the boxes, check them, and update them from this repo.

The repo is public. It must hold no tailnet domain, no `100.x` address, no key, and no per-box note.

Goal: one command, run on any box, shows the state of every devaloy box, and one agent procedure updates them all with no box left broken and no box on unpushed code.

Target: `devaloy fleet status` lists every online `devaloy-*` box with no file to edit when a box joins or leaves. `devaloy fleet update` stops at the first failed box. A grep of the repo for `ts.net` and `100.` addresses finds nothing new.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Source of the box list | The tailnet. `tailscale status --json` at run time. No committed inventory. |
| Box filter | The first label of `DNSName` starts with `devaloy-`, and `OS` is `linux`. Not `HostName`: on `devaloy-ovh`, `HostName` is the container name `devaloy` and only `DNSName` carries `devaloy-ovh`. |
| Tailscale tags | Not used. The owner keeps the `devaloy-` prefix for every box. Tags would also break an `autogroup:self` SSH rule. |
| Offline boxes | `fleet list` shows them as offline. `status`, `doctor` and `update` skip them. This also hides an old node that Tailscale kept after a reinstall gave the new node a `-1` name. |
| How to reach a box | `ssh dev@<first TailscaleIPs entry>`, read from the same status JSON, with `-o BatchMode=yes -o ConnectTimeout=10`. Inside the container the Docker resolver (`127.0.0.11`) does not resolve MagicDNS names, so `ssh devaloy-insta` fails and `ssh dev@<ip>` works. The address is read at run time and never stored. |
| The local box | `fleet` finds the self entry (`.Self`) and runs the verb locally, with no SSH. |
| Where `fleet` runs | Only on a box. From the Mac: `ssh devaloy-ovh devaloy fleet status`. No laptop-side script. |
| Where the code lives | A new module `lib/fleet.sh`, added to `DEVALOY_MODULES` and the verb dispatch in `devaloy`. It calls only existing verbs on the far box (`status`, `doctor`, `health`, `update`) and plain `git`, so a box with an older CLI still answers. |
| Runtime column | `RUNTIME` from `/opt/devaloy/build-flags` on the box. A missing line means container, the same rule as `devaloy_runtime` in `lib/common.sh:320`. |
| Clone column | `fleet list` shows the short commit and branch of `~/projects/devaloy`, with `*` for a dirty tree, or `no clone`. |
| Read-only verbs | `fleet status` and `fleet doctor` run on all online boxes in parallel. Output is buffered per box and printed as whole blocks in name order, each line prefixed `<box>:`. Exit status is non-zero when one box fails. |
| `fleet update` order | One box at a time: remote boxes by name, the local box last. After each box it runs `devaloy health` on that box. It stops at the first failure and names the box and the step. `fleet update <box>...` limits the run to the named boxes and refuses a name that is not in the filtered list. |
| Clone gate before update | In a container `devaloy update` installs the CLI and config from `~/projects/devaloy` (`lib/update.sh:58`, `lib/update.sh:104`), so the clone is the release. Before each box: `git fetch`, then require a clean tree on `main` that is not ahead of `origin/main`, then `git pull --ff-only`. Any other state stops the run before that box: a dirty tree names the files, another branch names the branch, an ahead count names the unpushed commits and the fix `git push`. |
| A box with no clone | Update from the image copy in `/opt/devaloy`, as `config_src` does today, and print `no clone` in the report. |
| The local update and the agent | `devaloy update` does not restart the container, but `mise prune` can remove the old Claude Code and Codex versions. The skill tells the agent to ask the human to restart the agent session after the local box updates. |
| Native boxes | Same path. The native installer creates the `dev` user with passwordless sudo and runs `tailscale up --ssh` (`scripts/install-native.sh:672`, `scripts/install-native.sh:728`), and `native_pull` already moves `/opt/devaloy`. No native box exists today, so this path has no live test. |
| Exclude list | None in the CLI. Box arguments limit a run. "Do not update" notes go in `fleet.md` for the agent. |
| Per-box notes | `~/.config/devaloy/fleet.md`, outside the repo, on the home volume. Free text for the agent: provider, runtime, update windows. The CLI does not read it. The repo commits `config/devaloy/fleet.example.md` with fake boxes only. |
| Agent procedure | A skill `config/claude/skills/devaloy-fleet/SKILL.md`, next to `devaloy-clean`. `devaloy update --config-only` copies it to `~/.claude/skills/`. |
| Test approach | No test runner exists in the repo. `shellcheck` on the new files, added to `config/mise/config.toml` in phase 1. A fixture: `DEVALOY_FLEET_STATUS_JSON=<file>` makes `fleet` read a saved status JSON instead of calling `tailscale`. A fixture with fake names lives in the scratchpad, never in the repo. |
| Live runs during the build | `fleet list`, `fleet status` and `fleet doctor` may run against `devaloy-insta` at any time. The first live `fleet update` waits for the owner's approval (phase 6). |
| Commits during the build | None. The build leaves all changes uncommitted for the owner to review. |

## Approach

Reuse:

- `devaloy` verb dispatch and module loader (`devaloy:60-80`).
- `devaloy_runtime` and `build_flag` in `lib/common.sh` for the runtime rule.
- `do_health` in `lib/doctor.sh` as the per-box check after update.
- `jq`, already in `config/apt/packages.txt`.
- The skill layout and seed path of `config/claude/skills/devaloy-clean/`.

Rejected: Ansible with a committed inventory. Two boxes do not need it, the `devaloy` CLI already does the per-box work, and an inventory exposes addresses. Rejected: a gitignored `hosts` file in the repo. `git add -A` or a fresh clone can lose or leak it, and Tailscale already holds the same data. Rejected: Tailscale tags, see the decision above.

### Phase 1: discovery and `fleet list` (built 2026-11-11)

- Add `shellcheck` to `config/mise/config.toml` and install it with `devaloy update`.
- Add `lib/fleet.sh` with `fleet_boxes`: read the status JSON (or the fixture), apply the filter, and print one TSV row per box: name, IP, online, self.
- Add `devaloy fleet list`: name, online state, runtime, and clone state.
- Add `fleet` to `DEVALOY_MODULES`, the verb dispatch, and the usage header in `devaloy`.

Done when: on `devaloy-ovh`, `devaloy fleet list` prints `devaloy-ovh` (marked self) and `devaloy-insta` with runtime `container` and a clone column, and does not print `beszel-ovh`, `brainaloy-ovh` or `mukit-macbook-air`. A fixture with an offline `devaloy-old` node shows it as offline. `shellcheck lib/fleet.sh devaloy` exits 0.

### Phase 2: `fleet status` and `fleet doctor` (built 2026-11-11)

- Run the verb on every online box in parallel, buffered per box, printed in name order with the `<box>:` prefix.
- Print a one-line summary per box at the end: ok or failed, with the exit code.

Done when: `devaloy fleet status` prints the status block of both boxes, one whole block per box, and exits 0. With a fixture entry that points to an unused address, the command reports that box as failed within 15 seconds and exits non-zero.

### Phase 3: `fleet update` (built 2026-11-11)

- Order the boxes: remote boxes by name, the local box last.
- On each box, run the clone gate, then `devaloy update`, then `devaloy health`. Stop at the first non-zero exit and print the box and the step.
- Accept box names as arguments. Refuse a name that is not in the filtered list.

Done when: with fixtures only, `devaloy fleet update devaloy-nope` is refused, and a fixture box with an unused address stops the run before the next box and exits non-zero. The gate function, run against a scratch clone in the session scratchpad, stops with the message the decision table names for each of three states: a dirty tree, a feature branch, and a commit ahead of `origin/main`. On a clean `main` that matches `origin/main`, it passes. No check runs `devaloy update`.

### Phase 4: notes file and the `devaloy-fleet` skill (built 2026-11-11)

- Add `config/devaloy/fleet.example.md` with fake boxes (`devaloy-example-a`, `devaloy-example-b`) and the fields the owner keeps.
- Write `config/claude/skills/devaloy-fleet/SKILL.md`. Steps: run `devaloy fleet list`; read `~/.config/devaloy/fleet.md` when it exists; run `fleet status` and `fleet doctor` before a change; ask the human before `fleet update` or any delete; update one box, read its health, then go on; after the local box updates, ask the human to restart the agent session.
- State in the skill that the agent never writes an address, a tailnet domain, or a note into the repo.

Done when: after `devaloy update --config-only`, `~/.claude/skills/devaloy-fleet/SKILL.md` exists, and `git grep -nE 'ts\.net|100\.[0-9]+\.[0-9]+\.[0-9]+'` finds no new match.

### Phase 5: documentation (built 2026-11-11)

- Add `docs/wiki/manage-the-fleet.md`: the naming rule, the commands, the clone gate, the notes file, and how to run it from the Mac (`ssh devaloy-ovh devaloy fleet status`).
- Link it from `docs/wiki/index.md` and `docs/wiki/manage-the-box.md`. Add the verb to `docs/wiki/reference.md`.

Done when: every read-only command in the new page runs as written on `devaloy-ovh`.

### Phase 6: live update check

Attended: the owner approves the first live `devaloy fleet update devaloy-insta`.

- Run `devaloy fleet list` and `devaloy fleet status`, and show the owner the result.
- After approval, run `devaloy fleet update devaloy-insta`.

Done when: `devaloy fleet update devaloy-insta` exits 0, its report shows the clone gate passed and `devaloy health` returned 0, and `devaloy fleet status` afterwards shows `devaloy-insta` online.

## Open questions

None. Every decision from the 2026-11-11 grill is settled.

## Non-goals

- Provisioning a new VM. `scripts/install-native.sh` and the container deploy stay as they are.
- Tailscale tags and changes to the tailnet policy file.
- A laptop-side fleet script. `fleet` runs only on a box.
- JSON output for `status`, `doctor` or `fleet`. The agent reads the prefixed text.
- An exclude list in the CLI.
- A `--ref` flag for `fleet update`. The gate allows `main` only.
- A web dashboard. Beszel already covers resource graphs.
- Arbitrary shell commands on all boxes (`fleet exec`). The agent can SSH to one box for that.
- Boxes outside the tailnet.
