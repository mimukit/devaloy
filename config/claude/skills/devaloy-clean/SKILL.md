---
name: devaloy-clean
description: >-
  Reclaim disk on this devaloy box with one human answer for each worktree and one for the delete: scan with `devaloy clean`, sweep merged worktrees with gitkit `clean`, then apply the saved scan. Use on a Beszel disk alert, when the user says "the disk is full" or "clean up the box", and every two weeks for the worktree sweep. A routine run every few days does not need this skill; run `devaloy clean`, read the report, then `devaloy clean --apply`.
---

# devaloy-clean

This skill holds no delete logic. It never deletes a file, a volume, an image or a branch itself. Every delete goes through `devaloy clean --apply --from <file>` or through the gitkit `clean` mode.

## Steps

### 1. Scan and save

Put the scan file in the session scratchpad. When the session has no scratchpad, use `mktemp`.

```sh
SCAN="<scratchpad>/devaloy-clean.tsv"    # or: SCAN="$(mktemp)"
devaloy clean --json --save "$SCAN" > "$SCAN.json"
df -h ~
```

Stdout is one JSON object. Its keys are `disk`, `docker` and `totals`. Each row is `{type, path, size_kb, note}`. The save message goes to stderr.

Show the human a short table. Give one line for each row type, with the count and the size in MiB. Add the Docker volume rows, the `docker.summary` lines and `totals.total_mib`. Show the `df -h ~` use percent below the table.

When `docker.available` is `false`, say that the Docker half is skipped.

### 2. Sweep the worktrees with gitkit

Invoke the gitkit skill in its `clean` mode. Do not do the sweep in this skill. gitkit asks one question for each row, and you keep that rule. Do step 3 before gitkit offers each merged branch.

### 3. Warn about local-only commits

Before gitkit offers a merged branch, look for commits that are on neither the remote nor the base branch. Use these read-only commands in that repo.

```sh
git -C "$REPO" log --oneline "$BRANCH" --not --remotes
git -C "$REPO" log --oneline "$BRANCH" --not "origin/$BASE" "$BASE"
```

When both lists show commits, warn the human before the gitkit question. Name the branch, and paste the commit list.

The gitkit removal rule already guards this case (`-d`, and `-D` only when the tip equals the merged `headRefOid`). The job of this step is to make the warning visible. On 2026-11-05, the unishopr-reborn `issue-123` and `issue-137` worktrees had merged PRs but held local commits that were on neither GitHub nor main.

### 4. Ask about unused images when the disk is above 85%

Read the use percent from `df -h ~`. When it is above 85%, read the `Images` line of `docker.summary` in `$SCAN.json`. Show its `reclaimable` size. Ask the human whether to add `--all`.

At 85% or below, do not ask. The apply then removes dangling images only.

### 5. Ask, then apply the saved scan

Show the total from step 1 again. Ask the human to confirm the delete. When the answer is yes, run the apply.

```sh
devaloy clean --apply --from "$SCAN"          # add --all when the human said yes in step 4
```

When the CLI refuses the file because it is older than 60 minutes, go back to step 1. Show the new report and ask again. Never edit the saved file.

### 6. Print the host checks

The skill cannot reach the host. The box has no sudo on the host and no host SSH user. Print these commands for the human to run on the host.

```sh
df -h /
docker system df
docker system df -v
systemctl list-timers docker-prune.timer
```

## Why this skill lives in the devaloy repo

Other skills come from `mimukit/skills`. This skill calls the CLI of this box and reads its JSON, so it must change in the same commit as `lib/clean.sh`. `devaloy update --config-only` copies `config/claude` into `~/.claude`, so the skill loads from any directory.
