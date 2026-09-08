# Plan: one `devaloy` command with an fzf TUI

Grilled: 2026-09-08

## Context

The box carries five separate management scripts: `devaloy-update`, `devaloy-disk`, `devaloy-ram`, `devaloy-prune` and `devaloy-nvim-sync`. Each one is well documented in its own header, and that is the problem. The documentation is only readable by running `--help` on a name you already remembered. There is no way to discover what the box can do, no shared status screen, and no path from "the disk is full" to the right script without knowing that `devaloy-disk` and `devaloy-prune` are different tools with different scopes.

The `ip` script in `mimukit/dotfiles` already solved this shape for network addresses: a keyboard-driven fzf picker with a menu at the root, `l`/`enter` to descend, `h`/`esc` to go back, and one fzf process per view. This plan ports that pattern to box management.

Success means one command, `devaloy`, opens on a status screen that answers "how is this box" with no keypress, and every management action is two or three keystrokes away with its dry-run report on screen before anything is deleted.

## Findings that settled part of the design

Established before the grill, so they are facts rather than choices:

- `mise latest fzf` resolves **0.74.3**, above the 0.65 floor `--footer` and `transform-footer` need. The registry entry is `aqua:junegunn/fzf`, the upstream release binary.
- `/usr/local/bin` precedes `/usr/bin` on the default PATH, and a mise-activated shell puts the mise install directories ahead of both. A mise fzf shadows the apt one in every session shape on this box.
- **Nothing executes the old script names.** All 30 references are documentation, `alias update='devaloy-update'` in `config/zsh/zshrc`, and log strings in `entrypoint.sh`. The compatibility symlinks protect habit and docs, not a caller.
- A Paseo pane exports `PASEO_AGENT_ID`, so `devaloy` can detect that a Paseo restart is about to kill its own terminal.
- Both `devaloy-disk` and `devaloy-ram` interleave the destructive call with the listing today (`act rm -rf` inside the print loop, `kill -TERM` inside the orphan loop). The two-phase design below restructures that.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Where the newer fzf comes from | `mise use -g fzf@latest` in `bootstrap-toolchain.sh`. The apt fzf stays as the cold-boot floor for LazyVim's pickers; the mise copy shadows it on PATH. |
| Old command names | Five symlinks in `/usr/local/bin` pointing at `devaloy`. `main` reads `$0`, and a basename of `devaloy-disk` prepends the `disk` verb. No wrapper script. |
| Behaviour on fzf below 0.65 | The TUI refuses with one line naming `devaloy-update` and exits 1. Every verb still runs non-interactively. No numbered-menu fallback. |
| How an action runs | fzf exits, the command streams on the raw terminal exactly as the scripts do today, and a keypress reopens the picker at the same row. No paging, no rendering output into the fzf list. |
| Report and apply | Two phases over a saved list. The scan writes its targets to a temp file, the report prints them, and the apply consumes that exact file. |
| Which callers get two phases | Both. `devaloy disk --apply` from the command line runs the same engine, so there is one delete path. `act()` survives, moved from inside the print loop to a second pass. |
| PID staleness in `ram` | The report records each PID's `/proc` start time, which it already reads for the age test. The apply re-checks it and skips any PID whose start time changed. |
| Paseo self-kill | Detected via `PASEO_AGENT_ID`. The confirm names "this pane dies with it" and still requires the explicit yes. It does not refuse and does not detach. |
| No TTY | `devaloy` with no TTY prints the status report as plain text and exits 0, the same shape as the `ip` script printing the public IPv4 into a pipe. |
| Status refresh | On `r`, and on return from an action view. Never on a timer. Each reading carries a `read at HH:MM:SS` stamp. |
| File layout | `devaloy` plus nine modules under `/usr/local/lib/devaloy/`. |
| Module seams | One module per verb, plus two shared: `common.sh`, `tui.sh`, `disk.sh`, `ram.sh`, `prune.sh`, `update.sh`, `nvim.sh`, `status.sh`, `doctor.sh`. |
| Locating the lib | `DEVALOY_LIB=${DEVALOY_LIB:-/usr/local/lib/devaloy}`, with the nine module names listed literally in `devaloy`. A missing module exits 1 naming the file. The override runs the script from a git checkout. |
| `doctor` exit code | Non-zero only when a capability the box was built with is broken. Absent by build flag is exit 0. This needs `/opt/devaloy/build-flags`, written by the Dockerfile. |
| Extra surfaces | A status overview as the root view, and a doctor view for the capability checks CLAUDE.md currently tells agents to run by hand. |

## Approach

One command, `devaloy`, backed by nine sourced modules. It reuses the `ip` script's architecture: `SELF` re-entry for internal modes, a `cmd_pick` loop that restarts fzf per view so `--height='~85%'` measures each view's own content, tab-delimited rows carrying `label / value / target-view / detail-view`, and `--expect` routing on the key that ended the run.

It reuses this repo's conventions too. Every destructive path still goes through `act()`, so the dry run and the real run cannot drift. `prune.sh` stays the single owner of the Docker reclaim, and `disk --docker` still delegates to it rather than duplicating its filters.

### Phase 1: newer fzf in the toolchain (built 2026-09-08)

Add `mise use -g fzf@latest` to `bootstrap-toolchain.sh`, next to `lazygit` and `neovim`, with a comment naming the 0.65 floor and the two options that need it. Leave `fzf` in the Dockerfile apt list and comment there that the apt copy is the cold-boot floor for LazyVim and that mise shadows it. Verify after a `devaloy-update` that `fzf --version` reports 0.74 or later and that `command -v fzf` resolves through a mise path.

### Phase 2: the loader, `common.sh`, and the status view (built 2026-09-08)

Write `devaloy` as argv parsing, `$0` verb inference, the `DEVALOY_LIB` resolution and the nine-module source loop with the hard-fail check. Write `common.sh` with `die`, `require`, `shq`, `act`, `read_cg`, `human`, `paseo_pids` and `paseo_tree`, lifted from the existing scripts. Write `tui.sh` with `cmd_pick`, `cmd_view`, `label_of`, `footer_of` and `parent_of`. Write `status.sh`: disk free on `$HOME`, cgroup RAM against the limit, Paseo daemon state, toolset revision from the bootstrap marker, and the timestamp stamp.

Add the fzf version guard and the no-TTY path in this phase, since both are properties of the entry point. Verify `devaloy` opens the picker, `ssh devaloy 'devaloy'` prints plain text and exits 0, and `DEVALOY_LIB=./lib ./devaloy` runs from the checkout.

### Phase 3: port the five verbs (built 2026-09-08)

Move each script body into its module, preserving flags and output text verbatim so the symlinked names behave identically:

- `update.sh` from `devaloy-update`
- `disk.sh` from `devaloy-disk`, keeping `--age`, `--caches`, `--docker`
- `ram.sh` from `devaloy-ram`, keeping `--paseo`, `--orphans`, `--age`
- `prune.sh` from `devaloy-prune`, keeping `--all`, `--age`
- `nvim.sh` from `devaloy-nvim-sync`, keeping `--no-backup`

Restructure `disk.sh` and `ram.sh` into the two-phase shape at the same time: the scan writes a target file, the report prints from it, and the apply reads it back. `ram.sh` records the `/proc` start time per PID and re-checks it. Keep the per-verb root refusal that `update` and `nvim-sync` have today.

Delete the five scripts, add the symlinks and the `COPY` in the Dockerfile, and update `.dockerignore`. Verify each old name produces byte-identical output to the current script for its dry-run path.

### Phase 4: the action views and the confirm (built 2026-09-08)

Give disk, ram and prune each a view that runs its report and shows the summary in the picker, with the full report streamed on the raw terminal. Bind `a` to a plain `read -r -p` confirm on that terminal, naming the counts and sizes from the report just produced, and the Paseo pane warning when `PASEO_AGENT_ID` is set. On yes, run the apply against the saved target file. Bind `r` to re-run the report. Refresh the status figures on return.

### Phase 5: build flags and the doctor view (built 2026-09-08)

Have the Dockerfile write `WITH_DOCKER`, `WITH_ORCA` and `WITH_PASEO` to `/opt/devaloy/build-flags`. Write `doctor.sh` to check Docker reachable, Orca runtime up, Paseo daemon up, `GITHUB_TOKEN` set, tailscale state, mise shims mirrored, and nine of nine modules present. Each row reads against the build flags, so absent-by-design and broken are different rows and different exit codes.

### Phase 6: docs (built 2026-09-08)

Update `docs/wiki/reference.md`, `docs/wiki/update-the-toolchain.md` and `README.md` for the new command. Add a wiki page for the TUI covering the key map, the confirm behaviour and the `doctor` exit codes. Keep `alias update='devaloy-update'` in `config/zsh/zshrc` working; the symlink covers it.

### Rejected alternatives

- A packaged TUI framework (gum, whiptail, a Go or Node binary). Every one adds a dependency to an image whose point is that a cold boot clones nothing, and fzf is already there.
- One long-lived fzf with `reload` bindings. The `ip` script tried this and `--height='~85%'` clipped every view after the menu to two rows.
- Keeping the five scripts and having `devaloy` shell out to them. Status and doctor need the internals (`read_cg`, `paseo_tree`), so the code ends up shared anyway.
- A single ~1,400-line `devaloy`. Rejected in favour of the module split, with the explicit manifest in Q13 covering the partial-`COPY` risk that made one file attractive.
- A numbered-menu fallback for old fzf. It is a second UI that nobody sees after one `devaloy-update`.

## Open questions

None. Every branch reached a decision in the grill.

## Non-goals

- No change to what any verb reclaims. The age windows, the exclusion lists and the safety rules stay exactly as they are; only the interleaving becomes two phases.
- No automatic or timed runs. `devaloy-prune`'s header states why the reclaim is a command you type, and that holds for the TUI.
- No configuration file. Flags and environment variables only, as in the `ip` script.
- No remote or multi-box operation. This manages the box it runs on.
- No change to `link-shims`, which is a root-only helper and not a user-facing verb.
