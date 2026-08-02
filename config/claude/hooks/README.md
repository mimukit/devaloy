# Claude Code hooks

Drop executable hook scripts here. They land at `~/.claude/hooks/` on the
devbox and are wired up by referencing them from
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

Keep hooks portable. This box has no GUI, no `osascript`, no desktop
notifications and no Orca — a hook copied from a Mac setup that shells out to
any of those will fail silently on every tool call.

Mark scripts executable **in git** (`git update-index --chmod=+x`), because the
copy into `~/.claude/` preserves the mode it finds in the repo.
