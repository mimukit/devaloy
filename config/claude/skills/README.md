# Claude Code skills

One directory per skill, each containing a `SKILL.md` with YAML frontmatter:

```
skills/
  mykit/
    SKILL.md
```

```markdown
---
name: mykit
description: What it does and when to use it — this line is what Claude matches on.
---

Instructions go here.
```

These land at `~/.claude/skills/` on the devbox and are available in every
project.

The copy is a **merge**, not a replace: a skill you add on the box by hand
survives a redeploy as long as no directory of the same name exists here.
A skill that *does* exist here is overwritten from this repo on every boot.
