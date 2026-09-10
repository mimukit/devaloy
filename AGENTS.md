# AGENTS.md

## Docs artifact naming

Every artifact under `docs/plans/` and `docs/qa/` (and other per-type artifact directories) is named:

```
NNNN-<type>-<slug>-YYYY-MM-DD.md
```

- `NNNN` is a four-digit zero-padded serial, monotonic and never reused, per directory. It records creation order.
- `<type>` matches the directory: `plan`, `qa`, `review`, `research`, `adr`, `handoff`, and so on.
- `<slug>` is a short lowercase kebab-case subject.
- `YYYY-MM-DD` is the ISO creation date, fixed even when the file is later edited.

Example: `docs/plans/0007-plan-browser-capture-2026-09-07.md`.

`docs/adr/` is the exception: an ADR keeps the decision number it was assigned, moved to the front, never re-derived from a date.

Reader-facing documentation under `docs/wiki/` is out of scope for this numbering; it is navigated by name, not by creation order.
