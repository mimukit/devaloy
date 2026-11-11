---
name: devaloy-fleet
description: >-
  Check, debug and update every devaloy box on the tailnet from one box with `devaloy fleet`: list the boxes, read status and doctor on all of them, then update them one at a time with the human's approval. Use when the user says "check all my boxes", "update the fleet", "update devaloy-insta", "is every box healthy", or names more than one devaloy box. For work on this box alone, use the plain `devaloy` verbs.
---

# devaloy-fleet

This skill holds no update logic. Every change to a box goes through `devaloy fleet update`, which runs the clone gate, `devaloy update` and `devaloy health` on each box.

The box list is the tailnet: every Linux node whose Tailscale name starts with `devaloy-`. There is no inventory file to edit.

## Rules

- Never write a Tailscale address, a MagicDNS domain, a key, a token or a box note into a repo. The devaloy repo is public.
- Ask the human before any `devaloy fleet update`, and before any delete on any box.
- Update one box at a time. Read its result before the next box.
- Run read-only commands freely: `fleet list`, `fleet status`, `fleet doctor`, and `ssh` reads on one box.

## Steps

### 1. Find the boxes

```sh
devaloy fleet list
cat ~/.config/devaloy/fleet.md 2>/dev/null
```

`fleet list` prints each box with its state, runtime and clone. The clone column is the branch and short commit of `~/projects/devaloy`. A `*` means uncommitted changes. `unreachable` means SSH failed.

`fleet.md` holds the human's notes: provider, role, and when a box must not update. Obey a "do not update" note. When the file is missing, say so once and go on.

### 2. Check before a change

```sh
devaloy fleet status
devaloy fleet doctor
```

Each line has a `<box>:` prefix. A summary at the end says `ok` or `failed (exit N)` for each box. Show the human one line per box. Name each failed doctor row.

To look closer at one box, find its address in `tailscale status --json` and run `ssh dev@<address> '<command>'`. MagicDNS names do not resolve inside a devaloy container. Do not write the address down anywhere.

### 3. Update with approval

Tell the human which boxes `fleet update` will change, in this order: far boxes by name, this box last. Ask for approval. Then update one box per run:

```sh
devaloy fleet update <box>
```

Each box gets three steps. The run stops at the first failure and names the box and the step.

1. **clone gate.** The clone must be clean, on `main`, and not ahead of `origin/main`. Then it fast-forwards. A box with no clone updates from `/opt/devaloy`.
2. **devaloy update.** Seeds config, installs the CLI from the clone, re-runs the toolchain bootstrap.
3. **devaloy health.** Must exit 0.

When the gate stops a box, report its message and the fix it names. Do not fix the clone yourself unless the human asks. A dirty tree or a feature branch can hold someone's work in progress.

### 4. Update this box last

The update of this box can replace the Claude Code or Codex binary that runs this session. After it ends, tell the human to restart the agent session.

### 5. Report

Give one line per box: updated, stopped (with the step), or skipped (with the reason). Run `devaloy fleet list` again and show the clone column, so the human sees every box on the same commit.
