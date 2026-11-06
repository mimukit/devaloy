# AGENTS.md

## One system install for both runtimes

devaloy runs as a container (`Dockerfile`, `entrypoint.sh`) and natively on a VM (`scripts/install-native.sh`, systemd units). Both call the same code, in three layers:

- `lib/system/`: apt repos, packages, the `dev` user, the CLI, `build-flags`. The Dockerfile runs it at build time through `lib/system/install.sh`; the installer sources it.
- `lib/steps/`: the per-boot work. `entrypoint.sh` and `devaloy-boot.service` call it.
- `bootstrap-toolchain.sh` and `config/mise/config.toml`: the user toolchain.

Put a change in one of these, or in `config/apt/`. Edit the `Dockerfile` or `install-native.sh` only for work that one runtime alone does: the image's fetch stage, entrypoint and healthcheck, or the VM's env file, systemd units, Docker address ranges and firewall. A change that edits both files for the same purpose is a sign the shared layer is missing a step.

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
