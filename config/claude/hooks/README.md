# Claude Code hooks

Drop executable hook scripts here. They land at `~/.claude/hooks/` on the
devaloy box and are wired up by referencing them from
[`../settings.json`](../settings.json) — the directory alone does nothing, a
hook only runs if a `hooks` block in `settings.json` names it.

Reference them by absolute path, since a hook's working directory is the
project Claude is working in, not this directory:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "/home/dev/.claude/hooks/my-hook.sh" }]
      }
    ]
  }
}
```

Keep hooks portable. This box has no GUI, no `osascript` and no desktop
notifications — a hook copied from a Mac setup that shells out to
any of those will fail silently on every tool call.

Mark scripts executable **in git** (`git update-index --chmod=+x`), because the
copy into `~/.claude/` preserves the mode it finds in the repo.

## What actually runs on the box

No hook script ships from this directory today, but hooks are wired in
`../settings.json` — all pointing at scripts installed elsewhere:

**`UserPromptSubmit`, `Notification`, `Stop` → `~/.local/bin/agent-push`.** ntfy
push notifications, in [`../../bin/`](../../bin) rather than here because Codex
runs the same script from `../../codex/hooks.json`.

There is deliberately **no `PreToolUse` entry**. It used to run `agent-hook` →
`rm-guard` on every Bash call to gate deletes; it was removed because this
container is disposable and meant to run unattended, so a prompt per `rm` cost
more than it saved. Don't re-add a hook that can block a tool call unless you
are prepared for it to stall a session with nobody at the keyboard.
