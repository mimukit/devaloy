# Plan — agent config parity: bring the laptop's Claude Code and Codex setup to devaloy

## Context

devaloy ships Claude Code and Codex from `mise`, but they arrive close to
stock. The laptop's setup — 21 kit skills, a shared hook dispatcher with an `rm`
guard, herdr session reporting, a tuned permission allowlist and model pins —
does not exist on the box. The practical effect is that the two environments are
not interchangeable: a session you'd run from the laptop with `/afkkit` or
`/implementkit` can't be run from the phone, which is the reason devaloy
exists.

Config-as-code already works here. `entrypoint.sh` merge-copies `config/claude/`
and `config/codex/` into `/home/dev` on every boot, and
`bootstrap-toolchain.sh` installs the toolchain behind a revision marker. This
plan fills those two channels with what the laptop already has, and adds a third
for skills.

Skills are the exception to config-as-code. They are **not** copied into this
repo — they are installed from their upstream repos by the
[skills.sh](https://www.skills.sh) CLI, which the box already has via
`npm:skills`. Vendoring 21 skill directories here would fork them from
`mimukit/skills` the day after it landed; the CLI is the thing that keeps
devaloy and a laptop on the same skills.

The box installs the **whole** `mimukit/skills` repo rather than a curated
subset. Skill authoring is iterative — a new kit gets written, tried, and
rewritten several times before it settles — and a skill you're still shaping is
exactly the one you want to reach from the phone. A curated list would mean
editing this repo every time, which is enough friction to stop it happening.

Success: SSH in from a phone, run `/statuskit` then `/afkkit`, and get the same
behaviour as the laptop — including the `rm` guard refusing the same deletes and
the herdr pane showing agent state.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| How skills get on the box | The `skills` CLI (`skills add mimukit/skills -g …`), never a file copy. Skills land in `~/.agents/skills` with symlinks into `~/.claude/skills` and `~/.codex/skills` — all inside the persistent volume, so they survive a redeploy. |
| Where the skill list lives | `bootstrap-toolchain.sh`, next to the `mise use -g` lines, under the same `TOOLSET_REVISION` gate. One file owns "what is installed on this box", tools and skills alike — but the list is `-s '*'`, not an enumeration. |
| Which skills | **Everything** in `mimukit/skills` — `-s '*'`. New skills authored on the laptop are on the box after one `devaloy-update`, with nothing to edit here. That's the point: a skill you're still experimenting with is the one you most want to reach from the phone. |
| `verifykit` and `orca*` | Installed anyway, and left broken. `verifykit` needs a real browser and `orcakit`/`orca-cli` need the Mac app; all three are inert markdown until invoked. Excluding them means maintaining an exclusion list, which defeats `-s '*'`. Instead, name them in the box's `CLAUDE.md`/`AGENTS.md` as skills that won't work here. |
| Pinning and refresh | Revision-gated like the toolchain — first boot installs, an ordinary redeploy skips, so nothing swaps under a live session. `devaloy-update` re-runs `skills add -s '*'` (**not** `skills update`, which only touches already-installed skills and would never see a newly authored one). |
| Hook plumbing | Adopt `agent-hook` + `rm-guard` verbatim from `~/.local/bin/`. Both are portable POSIX shell, and the Mac-only features (`terminal-notifier` toast, Orca worktree port cleanup) self-disable on the box with no edits. |
| Orca and desktop config | Excluded entirely — Orca hook relays, `terminal-notifier`, `notify =`, `[desktop]`, `[mcp_servers.*]`, Claude plugin marketplaces, host-specific `[projects]` and `[hooks.state]` blocks. |
| `CLAUDE.md` / `AGENTS.md` duplication | Left as two files for now. Deduplicating is a separate concern from parity; recorded as an open question. |

## Approach

Four phases. Phase 1 is the one that changes what the box can do; phases 2–4
are parity work on top of it and are independently useful.

**What this reuses:** `bootstrap-toolchain.sh`'s `TOOLSET_REVISION` marker
(gating, skip-on-redeploy, retry-on-failure semantics all come free),
`entrypoint.sh`'s `seed_config` merge-copy (already wired for both agent dirs),
`devaloy-update`'s `--force` path, `link-shims` for non-interactive PATH, and
the `npm:skills` CLI which is already resolvable on the box.

### Phase 1 — Skills via the skills.sh CLI

1. **Add `skills` to the toolchain.** `mise use -g npm:skills@latest` in
   `bootstrap-toolchain.sh`, alongside `pnpm`/`gh`/`turbo`.
2. **Install every skill.** After `mise install`, run what the laptop's `skmi`
   alias already runs, minus the `opencode` target:
   ```sh
   skills add mimukit/skills --global --skill '*' -a claude-code -a codex -y
   ```
   The agent id is **`claude-code`**, not `claude`, and `-a` is **repeated per
   agent**, not comma-separated — both confirmed against the CLI. `--all` would
   be shorthand for `-s '*' -a '*' -y`, but `-a '*'` also writes to `~/.cursor`,
   `~/.gemini` and friends, so the two agents are spelled out. `opencode` is
   dropped because it isn't in this box's toolchain.
3. **Bump `TOOLSET_REVISION` to 3.** This is what makes an already-provisioned
   volume pick the skills up on its next redeploy. The existing comment block on
   that constant already explains why; extend it to mention skills.
4. **Make failure non-fatal but retried.** The marker is written only on
   success, so a GitHub outage during `skills add` leaves the volume behind the
   revision and the next boot retries — the behaviour already documented for the
   toolchain. Confirm `set -euo pipefail` gives that, since `skills add` is the
   last step before the marker write.
5. **Wire the refresh path — `add`, not `update`.** `devaloy-update` calls
   `bootstrap-toolchain.sh --force`, and the `--force` path must re-run the
   **same `skills add … -s '*'`** from step 2. `skills update -g -y` only
   refreshes skills already in `~/.agents/.skill-lock.json`, so it would upgrade
   the 21 skills the box knows and never notice the 22nd you authored yesterday.
   Re-running `add` covers both: new skills installed, existing ones re-resolved.
   Confirm that's true — if `add` skips already-installed skills rather than
   refreshing them, the `--force` path needs `add` *then* `update`.
   The laptop keeps these as two separate aliases (`skmi` = add, `skup` =
   update), which is the same distinction drawn by hand.
6. **Make new skills a `devaloy-update`, not a redeploy.** This is the workflow
   the whole phase exists for, so it has to be stated in the repo README as one
   line: *push a skill to `mimukit/skills`, run `devaloy-update` on the box, it's
   there.* No `TOOLSET_REVISION` bump, no redeploy, no edit to this repo — the
   revision gate only governs the *unattended boot* path.
7. **Delete `config/claude/skills/`.** Its README documents the
   copy-a-directory workflow this phase replaces. Replace it with a README
   section covering: the publish → `devaloy-update` loop above; trying a skill
   without installing (`skills use <pkg>@<skill>`); pulling from a *different*
   repo ad hoc (`skills add <owner>/<repo> -g -a claude,codex`) and the fact
   that it survives redeploys but not a volume reset unless it goes into
   `bootstrap-toolchain.sh`; and `skills remove` for one that misbehaves.
8. **Ship the `skmi` / `skup` aliases.** Already added to
   `config/zsh/zshrc` under *devaloy conveniences*, mirroring the laptop's, so
   the muscle memory carries over. They give a manual path that doesn't route
   through `devaloy-update`, which matters mid-session when you've just pushed a
   skill and don't want to re-resolve the whole toolchain to try it.
9. **Name the skills that can't work here.** Add a line to the box's
   `CLAUDE.md` and `AGENTS.md`: `verifykit`, `orcakit` and `orca-cli` are
   installed but non-functional on this box — no browser, no Orca. Cheaper than
   an exclusion list, and it stops an agent burning a turn discovering it.

### Phase 2 — Hooks: `agent-hook` + `rm-guard`

1. **Ship both scripts.** New `config/bin/` in this repo, copied to
   `~/.local/bin/` by `entrypoint.sh` (a third `seed_config` call). Mark them
   executable in git (`git update-index --chmod=+x`) — the copy preserves the
   repo's mode.
2. **Wire the Claude entry** in `config/claude/settings.json`: `PreToolUse`
   matcher `Bash` → `bash "$HOME/.local/bin/agent-hook" claude PreToolUse`.
3. **Wire the Codex entry** in a new `config/codex/hooks.json`: same command
   with `codex`, no matcher (Codex has none — the dispatcher repeats the tool
   check itself for exactly this reason).
4. **Enable Codex hooks.** Add `[features] hooks = true` to
   `config/codex/config.toml`. Without it `hooks.json` is inert and steps 1–3
   silently do nothing.
5. **Handle Codex hook trust.** Codex records a `trusted_hash` per hook entry in
   `[hooks.state]`. Determine whether a hook shipped by config-as-code needs
   that entry pre-seeded, or whether Codex prompts once on first use — a prompt
   nobody sees on a headless box is a hook that never fires.
6. **Verify the guard tiers on Linux.** `rm-guard`'s `SYSTEM_ROOTS` already
   lists `/home` and `/root`. Confirm the catastrophic tier blocks
   `rm -rf /home/dev`, and that a tracked-file delete inside a repo still
   passes.

### Phase 3 — herdr agent state

herdr is in the toolchain and is the reattachable-session story the README
leads with, but neither agent reports into it — so panes won't show
working/idle.

**Resolved during implementation — step 4 won, steps 1–3 were dropped.** herdr
ships `herdr integration install <target>`, with `claude` and `codex` among its
targets, writing exactly the scripts vendoring would have copied to exactly the
paths they belong at. `herdr integration status` reports the installed version
per agent. So:

1. `bootstrap-toolchain.sh` runs `herdr integration install` for `claude` and
   `codex` after `mise install`. Non-fatal, unlike the skills install — a
   missing pane indicator is cosmetic and not worth costing the volume its
   revision marker.
2. Wire `SessionStart` in `config/claude/settings.json` and
   `config/codex/hooks.json`. The *wiring* stays ours even though the *scripts*
   are herdr's: this repo overwrites both files on every boot, so anything herdr
   added to them would be dropped.
3. **Nothing vendored.** A copy in git would freeze claude v7 / codex v6 and
   need re-copying after every herdr upgrade; letting herdr own the file means
   an upgrade fixes the integration on the next `devaloy-update`.

### Phase 4 — Settings and config parity

**`config/claude/settings.json`** — adopt from `~/.claude/settings.json`:

- `env.DISABLE_TELEMETRY: "1"`
- `attribution: {commit: "", pr: ""}` — and drop `includeCoAuthoredBy: false`,
  which it supersedes
- `permissions.defaultMode: "auto"`
- the wider allowlist: `git:*`, `find:*`, `grep:*`, `wc:*`, `xargs:*`, `npm:*`,
  `pnpm:*`, and the `gh issue *` set, with `gh issue delete*` denied
- `model` and `effortLevel`
- keep the existing deny list as-is; it's already stricter than the laptop's

The allowlist plus `defaultMode: auto` is what makes an unattended `/afkkit`
run possible over SSH — without it every `gh issue` call stalls on a prompt
nobody is there to answer.

**`config/codex/config.toml`** — add `model`, `model_reasoning_effort`, and
`[tui] status_line` + `status_line_use_colors` (the only status readout you get
in a terminal-only session). Keep the existing `approval_policy` and
`sandbox_mode`; they are deliberately stricter than the laptop's and this plan
does not relax them.

**`config/codex/rules/default.rules`** — port the laptop's prefix-rule
allowlist (`git add`/`commit`/`diff --staged`/`push`/`fetch`), dropping the
`orca` lines. This is Codex's counterpart to the Claude allowlist above.

**Close the read asymmetry.** `config/claude/settings.json` denies reading
`.env`, `~/.devaloy_secrets`, `~/.codex/auth.json` and
`~/.claude/.credentials.json`. Codex has no equivalent — `workspace-write`
restricts *writes*, not reads, so Codex on the box can read `GITHUB_TOKEN` out
of `~/.devaloy_secrets` today. Find the Codex mechanism that closes this, or
record explicitly that it can't be closed and why that's acceptable.

**`CLAUDE.md` / `AGENTS.md`** — add three things the box's copies drop:

- the afkkit carve-out on "never commit" (afkkit auto-commits by design; a flat
  prohibition contradicts a skill Phase 1 installs)
- background-process cleanup — more relevant here, not less: a stray `pnpm dev`
  outlives the SSH session
- a delete section describing the guard's actual tiers, once Phase 2 lands

**Statusline (optional).** `~/.claude/statusline.sh` is jq-based and otherwise
portable, but `fmt_reset()` uses BSD `date -j -u -f` and `date -r`, which fail
on Ubuntu. Needs a `date -d` branch before it can ship. Low value once Codex's
`[tui] status_line` is on; do it last or not at all.

## Open questions

- Does `skills add` write anything outside `/home/dev`? If it caches to
  `$XDG_CACHE_HOME` outside the volume, a redeploy silently re-downloads.
- Does re-running `skills add -s '*'` refresh already-installed skills, or skip
  them? Step 5 of Phase 1 depends on the answer; if it skips, `devaloy-update`
  needs `add` followed by `update`.
- Installing `-s '*'` means a skill authored on the laptop lands on the box
  with no review step. Given the box has passwordless sudo and a live
  `GITHUB_TOKEN`, and skills are instructions an agent follows — is
  push-to-`mimukit/skills` the right trust boundary, or should the box track a
  tag/branch rather than `main`?
- Does `skills remove` on the box get undone by the next `devaloy-update`? With
  `-s '*'` it presumably reinstalls, which makes removal impossible without an
  exclusion list — the thing this decision was meant to avoid.
- How does Codex's `[hooks.state]` trust model behave for a hook that arrives
  via config-as-code and changes hash on every redeploy? This could make Phase 2
  and 3 no-ops on the Codex side.
- Should `git-commit` (from `github/awesome-copilot`) come along? It's installed
  on the laptop and overlaps `commitkit`.
- `CLAUDE.md` and `AGENTS.md` are ~90% duplicated prose that will drift. Symlink
  one to the other, generate one from the other, or accept the drift?
- The Claude allowlist plus `defaultMode: auto` is a real widening on a box with
  passwordless sudo and a live `GITHUB_TOKEN`. Is `auto` the right default, or
  should the box stay stricter than the laptop and accept the prompts?
- `mise use -g npm:skills@latest` tracks latest, and `skills` gates what runs in
  every agent session. Worth pinning?

## Non-goals

- **Vendoring skill files into this repo.** The CLI owns skill installation.
- **Curating which skills reach the box.** The box takes all of
  `mimukit/skills`; skills that can't work headless are documented, not filtered.
- **Making `verifykit` or the Orca skills work here.** They need a browser and a
  Mac app respectively. Out of scope, probably permanently.
- **Anything Orca, desktop, or macOS.** No hook relays, no `terminal-notifier`,
  no `[desktop]`, no `computer-use`/`node_repl` MCP servers, no plugin
  marketplaces.
- **Relaxing the Codex sandbox.** `approval_policy = "on-request"` and
  `sandbox_mode = "workspace-write"` stay as they are.
- **Syncing the laptop *from* this repo.** The laptop stays chezmoi-managed;
  this is one-directional.
- **Per-project agent config.** Global `~/.claude` and `~/.codex` only.
- **Credential sync.** Agent logins stay per-box and are already persisted in
  the volume.
