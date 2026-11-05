# Plan: Routine disk reclaim with `devaloy clean`

Grilled: 2026-11-05

## Context

On 2026-11-05 Beszel reported the host brainaloy-ovh (96G disk) at 92%. A manual agent session took it to 73% (70G used, 27G free). Most of that session was rule work that the `devaloy` CLI does not do yet, so the next full disk needs the same manual session again.

What the session freed, and what the CLI covers today:

| Freed | Size | CLI today |
|---|---|---|
| Nested Docker build cache | 4.7G | Partial: `devaloy prune` takes only cache older than 168h |
| Unused Docker images | 1.8G | Yes, `devaloy prune --all` |
| Anonymous Docker volumes that no container uses | 1.5G | No |
| `~/.cache/pnpm`, `~/.npm/_npx` | 2.4G | Partial: `--caches` lists `~/.npm`, not `~/.cache/pnpm` or `~/.local/share/pnpm/package-manager-store` |
| Old Playwright revisions in `~/.cache/ms-playwright` (kept rev 1252, which `playwright-cli` pins; removed 1243, 1247 and an old ffmpeg) | 1.3G | No |
| `pnpm store prune` | 2.9G | Yes with `--caches`, but see the bug in Phase 1 |
| node_modules in linked worktrees with a clean tree and no unpushed commits | 3G | No: the age test reads the node_modules mtime, and these were recent |
| Merged worktrees and local branches, through gitkit `clean` | ~5G | `devaloy disk` lists them and defers to gitkit |
| Agent logs older than 30 days (`~/.codex/sessions`, `~/.claude/projects`, `~/.t3/userdata/logs`) | 52M (2.6G at a 7-day cutoff) | No: Paseo daemon logs only |
| Stale mise versions | 0 that day | Yes, `mise prune` |

Other facts from the session:

- A `devaloy disk --caches` dry run also found 3.1G of node_modules older than 30 days, mostly under `projects/saasaloy/.dev/playground` and `projects/360engineering`. It also found Claude Code agent worktrees under `projects/saasaloy/.claude/worktrees/agent-*` (branches `review-278`, `review-279`, `review-286`).
- The aube store (`~/.local/share/aube`, 4.2G) must stay. mise npm tools symlink into `~/.cache/aube/virtual-store`.
- Two merged-PR worktrees (unishopr-reborn `issue-123` and `issue-137`) had local commits that were on neither GitHub nor main. Worktree removal therefore stays a judgment step.
- The host needs no change. `scripts/host-resource-guard.sh` installs a weekly docker prune timer. On the host, build cache was 0 and every image was in use. Host disk is mostly Docker volumes (47.8G), and the devaloy home volume is ~37G of that.

Facts found during the grill:

- The nested daemon is Docker 29.9.3.
- BuildKit's `reservedSpace` is the cache size the GC always keeps. With `defaultReservedSpace: 10GB` in `config/docker/daemon.json`, the GC never touches a cache under 10GB, so the CLI age filter is the only thing that frees it.
- Codex reads skills from `~/.agents/skills` and `~/.codex/skills`. The `config/claude` seed does not reach Codex.

Goal: routine reclaim on the box is a command the owner types every few days, not an agent session. A rule decides everything it can, and an agent skill handles only the judgment steps.

Target: on a box in the 2026-11-05 state, `devaloy clean --apply` frees at least 15G with no hand-typed `rm`. The rule-decidable rows in the table above sum to about 17.6G (proposed; baseline is the 2026-11-05 session table; measured at the owner's first real-box run). Between runs, the host disk stays under 80% on Beszel (measured after release).

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Split | Every rule-decidable delete goes into the `devaloy` CLI. The `devaloy-clean` skill holds no delete logic. It calls the CLI and gitkit `clean`, and it asks the human. |
| Verb name | `devaloy clean`, and the skill is `devaloy-clean`. `CONTEXT.md` does not change: its "cleanup" entry under _Avoid_ for _Reclaim_ stays as it is (owner's pick, 2026-11-05). |
| Contract | `clean` keeps the reclaim contract of `lib/disk.sh` and `lib/prune.sh`: scan to a target file, report from that file, apply from that file only. Dry run by default, one `--apply`. |
| Verb shape | New module `lib/clean.sh`, added to `DEVALOY_MODULES` in `devaloy` and to the verb list in `main`. It calls `disk_scan`, `prune_scan` and their apply functions. It does not copy their filters. `lib/**` is already in `.dockerignore`, so the image needs no other change. |
| `clean` defaults | Disk caches on (the `--caches` set), `--no-caches` turns them off. The Docker half runs. The age-based node_modules rule stays on at 30 days, the same as `devaloy disk`. Agent logs stay off until `--logs <days>`. |
| Build cache in `clean` | `clean` passes `--builder-age 24h` to the prune half. `devaloy prune` keeps 168h as its own default. `config/docker/daemon.json` does not change. |
| Images in `clean` | Dangling images only. `--all` passes through. The skill shows the `--all` size from `docker system df` and asks about it when the disk is above 85%. |
| pnpm store | Never `rm -rf`. The store gets a size-report row (like the `mise` row), and the apply runs `pnpm store prune` once. |
| Never-delete list | `~/.local/share/pnpm/store`, `~/.local/share/aube`, `~/.cache/aube`, `~/.local/share/mise` (except through `mise prune`), and `~/.claude/projects/*/memory`. The scan states the list in one place in `lib/disk.sh`, and the apply refuses a row under any of these paths. |
| Playwright rule | Keep every revision named in any `playwright-core/browsers.json` under `~/.cache/aube/virtual-store` and the mise installs. Delete other `~/.cache/ms-playwright/<browser>-<rev>` directories. The box has two `playwright-core` versions in the aube virtual store today (1.63 and 1.65), so the rule keeps the union, not the pin of one copy. |
| Worktree node_modules rule | A new row type `wtnm`. It qualifies a node_modules at a linked worktree's root, whatever its age, when `git status --porcelain` is empty, `git rev-list HEAD --not --remotes` is empty, and no process has its cwd under the worktree. `--not --remotes` also covers a branch with no upstream. The main checkout never qualifies. |
| `wtnm` and the network | The scan runs no `git fetch`. A squash-merged branch whose remote branch is gone fails `--not --remotes`, so the rule skips it, and gitkit `clean` handles that worktree. |
| `wtnm` at apply | The apply checks the three conditions again for each `wtnm` row before it deletes, because a commit can land between scan and apply. |
| Agent worktrees | `projects/*/.claude/worktrees/agent-*` are linked worktrees, so the `wtnm` rule applies to their node_modules. Their removal goes to gitkit `clean` like any other worktree. The CLI lists them in the `wt` section with no special case. |
| Agent logs | Opt-in `--logs <days>`, with a floor of 7. In scope: `*.jsonl` under `~/.codex/sessions`, each `<uuid>.jsonl` under `~/.claude/projects/*/` together with its `<uuid>/` directory, and files under `~/.t3/userdata/logs`. The `memory/` directories are never in scope. The report says that a deleted session can no longer be resumed. |
| Docker volumes | A new row type for each anonymous volume (64-hex name) with no container, from `docker volume ls -qf dangling=true`. The apply runs `docker volume rm <name>` for each listed row, not `docker volume prune`, so a volume that appears after the scan is never taken. Named volumes are never listed. |
| Machine report | `--json` on `clean`, built from the TSV target files with `jq` (the image installs it, `Dockerfile:118`). TSV stays the internal format. The `lib/clean.sh` header documents the row schema. A change may add a field, never rename one, because the skill reads it. |
| Saved scan | `devaloy clean --save <file>` writes the scan rows. `devaloy clean --apply --from <file>` applies those rows only, after it checks each row's type and path. It refuses a file older than 60 minutes. This lets the skill apply the exact list the human saw, across two processes. |
| TUI | `clean` gets a view. It is one line each in `cmd_view`, `label_of`, `footer_of`, `apply_of`, `detail_of` and `scan_of` in `lib/tui.sh`, plus a root branch row. Its `a` asks one `confirm` for both scans. |
| Worktrees and branches | Out of the CLI. gitkit `clean` owns removal, one confirmation per row. The CLI keeps the `wt` rows as a list and `git worktree prune` only. |
| Skill location | `config/claude/skills/devaloy-clean/SKILL.md` in this repo. `do_config_seed` in `lib/update.sh` copies `config/claude` into `~/.claude`, so the skill loads from any directory. This is a deliberate exception to "skills come from `mimukit/skills`": the skill calls this box's CLI and must change in the same commit as the CLI. A project skill under `.claude/skills/` would load only inside this repo. Claude Code only for now. |
| Host checks | The skill prints host commands for the human. It cannot run them: the box has no sudo on the host and no host SSH user. |
| Tests | No new test runner. Each phase checks its result with a dry run and a scripted scratch tree under a temporary `HOME` (`DISK_ROOT` follows `HOME`), recorded in its QA plan under `docs/qa/`. |
| Acceptance runs | Every disk `--apply` in a `Done when:` runs against a scratch `HOME`, never the real one. A Docker `--apply` check runs with `--from` a saved file that lists only a volume the check created. On the real box, a build runs dry runs only. The first real-box apply is the owner's rollout step. |
| Docs | Each phase updates the pages that document its flags: `README.md`, `docs/wiki/manage-the-box.md`, `docs/wiki/reference.md`, `docs/wiki/run-a-project-stack.md` and `docs/wiki/vm-resource-limits.md`, as each applies. The `-h` text comes from the file header through `sed -n '2,32p'` (disk) and `sed -n '2,26p'` (prune), so a header edit also moves those line ranges. |
| Outward actions | Approved on 2026-11-05: file one devaloy issue that carries all eight phases, through issuekit. |

## Approach

The work extends the two reclaims that exist. `lib/disk.sh` gets new row types and a fixed caches list. `lib/prune.sh` gets the volume rows and a build-cache age flag. A thin `lib/clean.sh` runs both in sequence. A skill sits on top for the steps a rule cannot decide.

Rejected alternatives, one line each:

- A skill that holds the rules: it repeats the same judgment each run, and it cannot run without an agent.
- A timer for the safe tier now: the store bug in Phase 1 shows that the apply paths need manual runs first.
- `docker volume prune` at apply: it takes volumes the scan did not list, which breaks the contract.
- A lower `defaultReservedSpace` in place of the 24h age: it needs an image rebuild, and the GC runs only under disk pressure.

### Phase 1: stop `--caches --apply` from deleting the pnpm store

- In `disk_scan`, remove `${DISK_ROOT}/.local/share/pnpm/store` from the `cache` path list.
- Add a `pstore` row with the store size and the note "pruned with pnpm store prune, never deleted".
- In `disk_apply_targets`, handle `pstore` once, like `mise`. Move the `pnpm store prune` call into that case, and remove it from the `DISK_DO_CACHES` block.
- Show the `pstore` row in `disk_report` and `rows_disk`, and take it out of the MiB sum in `disk_apply`.

Done when: on the real box, `DEVALOY_LIB=./lib ./devaloy disk --caches` prints `would run: pnpm store prune` and no path under `.local/share/pnpm/store`. In a scratch `HOME` with a populated `.local/share/pnpm/store`, `devaloy disk --caches --apply` leaves that directory and its files in place.

### Phase 2: cache and Playwright targets

- Change the `cache` list to `~/.cache/pnpm`, `~/.npm/_npx`, `~/.local/share/pnpm/package-manager-store`, `~/.cache/mise` and `~/.cache/turbo`. Keep `npm cache clean --force` for `~/.npm/_cacache`, and stop the `rm -rf` of all of `~/.npm`.
- Add the never-delete list as one variable, and make `disk_apply_targets` refuse any row under it.
- Add a `pw` row type for each `~/.cache/ms-playwright/<browser>-<rev>` that no `browsers.json` names (see Design decisions). Skip `daemon` and `cli-update-check.json`.
- When no `browsers.json` is found, write no `pw` rows and say why in the report.

Done when: on the real box, a dry run lists `chromium-1252` and `chromium_headless_shell-1252` as kept. In a scratch `HOME` with revisions 1243, 1247 and 1252 and one `browsers.json` that names 1252, `--apply` removes 1243 and 1247 only. A row added by hand under `~/.local/share/aube` is refused.

### Phase 3: node_modules in clean linked worktrees

- Add the `wtnm` row type and its scan (see Design decisions). Find linked worktrees through `git worktree list --porcelain` of each repo the `wt` scan already finds.
- Skip a `wtnm` candidate that the age-based `nm` scan already lists, so a path appears once.
- Add the check again in `disk_apply_targets` before `rm -rf`, and report a skipped row with its reason.
- Give `wtnm` its own report section with the worktree path, the branch and the size.

Done when: in a scratch repo under a temporary `HOME`, a dry run lists the node_modules of a clean, pushed worktree. It does not list the node_modules of a worktree with one dirty file, a worktree with one commit not on any remote, or a worktree where a `sleep` process has its cwd. A commit made between scan and apply makes the apply skip that row.

### Phase 4: agent logs behind `--logs <days>`

- Add `--logs <days>` to `disk_args`, and refuse a value under 7.
- Write one `alog` row for each matching file or Claude session directory (see Design decisions). Group them by top directory in the report, with a count and a size for each.
- Update the header and the `disk_usage` line range.

Done when: in a scratch `HOME` with old and new session files, a `<uuid>/` directory beside an old `<uuid>.jsonl`, and an old file under `memory/`, `devaloy disk --logs 30 --apply` removes the old sessions and their directories and leaves `memory/` in place. `devaloy disk --logs 3` exits non-zero with a message about the floor. Without `--logs`, the report says "agent logs: not scanned".

### Phase 5: Docker volumes and the build-cache age

- In `prune_scan`, write anonymous unused volumes with their size from `docker system df -v` to a second target file in the disk row format (TYPE, PATH, SIZE_KB, NOTE).
- In `prune_apply_targets`, run `docker volume rm` for each listed volume. Docker refuses a volume in use, so report that and continue.
- Add `--builder-age <dur>` to `devaloy prune`, default 168h.
- Record in the `lib/prune.sh` header that the builder GC keeps 10GB of reserved cache, so the age filter is what frees a cache under that size.

Done when: after `docker run -v /data alpine true` and `docker rm` of that container, a dry run lists the new volume and no named volume. `devaloy prune --builder-age 24h` prints `would prune build cache older than 24h`. The apply check for volumes is in Phase 7.

### Phase 6: the `devaloy clean` verb and its TUI view

- Add `lib/clean.sh` with `clean_args`, `clean_scan`, `clean_report`, `clean_apply_targets`, `clean_apply`, `rows_clean` and `do_clean`.
- `clean_args` takes `--apply`, `--all`, `--logs <days>`, `--age <days>` and `--no-caches`, and passes each to the disk or prune half. It always passes `--builder-age 24h`.
- Print one report: the disk sections, then the Docker sections, then one total.
- Add `clean` to `DEVALOY_MODULES`, to the verb case in `main`, to the `Modes` block in the `devaloy` header, and to the six TUI tables in `lib/tui.sh`.

Done when: `devaloy clean` prints one report and ends on `dry run. Nothing was deleted.`. In a scratch `HOME`, `devaloy clean --apply` removes the same disk rows that `devaloy disk --caches --apply` removes. In the picker, the `clean` view opens, and its `a` asks one confirm.

### Phase 7: machine report and saved scan

- Add `--json` to `clean`. It prints one JSON object with `disk`, `docker` and `totals` keys, each row as `{type, path, size_kb, note}`. Document the schema in the `lib/clean.sh` header.
- Add `--save <file>` and `--from <file>`. `--from` refuses a file older than 60 minutes. It checks each row's type against the known types, checks its path against `DISK_ROOT` and the never-delete list, and drops a row that fails with a message.
- `--from` without `--apply` prints the report for that file and deletes nothing.

Done when: `devaloy clean --json | jq '.totals'` prints the totals. A row edited in a saved file to point at `~/.local/share/aube` is dropped at `--apply --from` with a message. A saved file with its mtime set 61 minutes back is refused. After the Phase 5 volume setup, `--apply --from` a saved file that lists only the new volume removes it, and `docker volume ls` still shows every other volume.

### Phase 8: the `devaloy-clean` skill

- Write `config/claude/skills/devaloy-clean/SKILL.md`. The skill does these steps:
  1. Run `devaloy clean --json --save <scratch file>` and show the report.
  2. Run gitkit `clean` for the worktree sweep, one answer for each row.
  3. Warn about each merged branch with local commits that are on neither the remote nor the base branch, with the commit list, before gitkit offers it.
  4. When the disk is above 85%, show the `--all` image size and ask about it.
  5. Ask before the delete, then run `devaloy clean --apply --from <scratch file>`, with `--all` when the human said yes in step 4.
  6. Print the host checks as commands for the human: `df -h /`, `docker system df`, `docker system df -v`, `systemctl list-timers docker-prune.timer`.
- State in the skill that it holds no delete logic and never runs `rm` itself.

Done when: after `devaloy update --config-only`, `~/.claude/skills/devaloy-clean/SKILL.md` exists and its frontmatter `name` is `devaloy-clean`. `grep -nE '\brm\b|docker (volume|image|builder) (rm|prune)' config/claude/skills/devaloy-clean/SKILL.md` prints nothing. Every `devaloy` command the skill names is accepted by `devaloy clean -h`.

## Rollout

- First run, by the owner: `devaloy clean`, read the report, then `devaloy clean --apply` on the real box. This run also measures the 15G target.
- Every few days: `devaloy clean`, read the report, then `devaloy clean --apply`.
- On a Beszel alert, or every two weeks: the `devaloy-clean` skill, for the worktree sweep.
- Never put worktree deletion on a timer.
- A timer for the safe tier comes later, after Phase 1 ships and after a few manual runs show clean reports. That step needs its own plan.

## Open questions

None. All were settled in the grill on 2026-11-05.

## Non-goals

- Removing worktrees or branches from the CLI.
- Any change on the host. The host resource guard already covers it.
- A timer or cron job in this plan.
- Deleting the aube store, the pnpm store, mise installs outside `mise prune`, or agent memory.
- A glossary change in `CONTEXT.md`.
- A Codex copy of the skill.
- A live `/devaloy-clean` session as a build check.
- A new test runner for the shell modules.
- Any change to the owner's uncommitted edit in `Dockerfile`.
