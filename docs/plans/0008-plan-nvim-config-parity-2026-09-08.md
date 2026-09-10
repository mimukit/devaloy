# Plan: ship my LazyVim config on devaloy by default

Drafted: 2026-09-08

## Context

devaloy installs Neovim from mise and clones the LazyVim starter into `~/.config/nvim` on a cold volume (`bootstrap-toolchain.sh`, the `--- LazyVim ---` block). The starter is upstream's blank template: no options, no keymaps, no colorscheme, no extras. My own LazyVim config lives in `mimukit/dotfiles` under `dot_config/nvim` and is what I use on the laptop. Opening a file on devaloy today means relearning the editor.

The fix is to make devaloy seed my config instead of the starter, so a fresh box gives the same editor as the laptop.

Success: on a box with no `~/.config/nvim`, `devaloy-update` seeds the config, `nvim` starts with tokyonight transparent, `scrolloff` 20, `;` opening command mode, and the snacks explorer on the right showing hidden files. On a box that already has a config, nothing is overwritten until I run the sync command by hand.

### What the config actually contains

Read from `mimukit/dotfiles@main` on 2026-09-08.

| File | What it carries |
|---|---|
| `init.lua` | Upstream starter, one line. |
| `lua/config/lazy.lua` | Starter, with `checker.enabled = true` and `notify = false`. |
| `lua/config/options.lua` | `have_nerd_font`, `clipboard = ""`, `breakindent`, `listchars`, `scrolloff = 20`, `wrap`, `cmdheight = 0`, fold settings for ufo, 2-space tabs. |
| `lua/config/keymaps.lua` | `;` to `:`, centred `n`/`N`, four Navigator maps, five system-clipboard maps. |
| `lua/config/autocmds.lua` | Disables diagnostics on `*.env*`. |
| `lua/plugins/colorscheme.lua` | tokyonight, transparent, transparent sidebars and floats. |
| `lua/plugins/snacks.lua` | Explorer on the right, files picker shows hidden and gitignored. |
| `lazyvim.json` | Three extras: `lang.json`, `lang.toml`, `util.dot`. |
| `lazy-lock.json` | Resolved plugin commits from the laptop. |
| `dot_neoconf.json`, `stylua.toml`, `dot_gitignore` | neoconf/neodev settings, Lua formatting, editor scratch ignores. |
| `lua/plugins/example.lua` | Inert. First line is `if true then return {} end`. |

## Design decisions (settled)

| Decision | Resolution |
|---|---|
| Where the config lives | Vendored into the devaloy repo at `config/nvim/`, copied into the image by the existing `COPY config /opt/devaloy/config` (Dockerfile:374). No network call to `mimukit/dotfiles` at boot, no chezmoi `dot_` renaming at runtime, and no new tool. Cost: the config now exists in two repos and I update both. |
| What happens on a redeploy | Seed once, plus a refresh command. `bootstrap-toolchain.sh` keeps its `[ ! -d ~/.config/nvim ]` guard and copies from `/opt/devaloy/config/nvim` instead of cloning the starter. A new `devaloy-nvim-sync` re-copies on demand. My edits on the box survive every `docker compose up --build`. |
| The Navigator keymaps | Dropped. `numToStr/Navigator.nvim` is not in the config, so `<CMD>NavigatorLeft<CR>` would print `E492` on every press. LazyVim's own `<C-h/j/k/l>` window maps take over, so split-to-split movement still works. What is lost: the hop out to a tmux pane and the terminal-mode variant. |
| `lazy-lock.json` | Vendored. Parity is the goal, and the lockfile is what makes the plugin set identical rather than merely similar. `:Lazy update` on the box drifts it, which is fine because the box copy is mine to drift. |
| `example.lua` | Not vendored. It returns an empty spec on its first line and does nothing. |
| Seeding mechanism | NOT `seed_config()` in `entrypoint.sh`. That helper is a merge copy that overwrites matching files on every boot, which is exactly the overwrite the guard exists to prevent. The seed stays in `bootstrap-toolchain.sh` where the starter clone is today. |

## Approach

Replace the starter clone with a vendored copy, and add one script. Everything reuses machinery the repo already has.

**Reused as-is:** `COPY config /opt/devaloy/config` (Dockerfile:374) carries the new directory into the image with no Dockerfile change to the copy itself. The `[ ! -d "${HOME}/.config/nvim" ]` guard and the headless `nvim --headless "+Lazy! sync" +qa` warm-up already exist in the LazyVim block. `COPY --chmod=755 ... /usr/local/bin/` (Dockerfile:362) is where the new script joins `devaloy-update` and `devaloy-prune`. `docs/wiki/reference.md` already tables the `devaloy-*` commands.

### Phase 1: vendor the config into `config/nvim/` (built 2026-09-08)

- Copy from `mimukit/dotfiles@main:dot_config/nvim`, renaming the chezmoi names: `dot_neoconf.json` to `.neoconf.json`, `dot_gitignore` to `.gitignore`.
- Files: `init.lua`, `lazyvim.json`, `lazy-lock.json`, `stylua.toml`, `.neoconf.json`, `.gitignore`, `lua/config/{lazy,options,keymaps,autocmds}.lua`, `lua/plugins/{colorscheme,snacks}.lua`.
- Skip: `LICENSE`, `README.md`, `lua/plugins/example.lua`.
- In `keymaps.lua`, delete the four Navigator lines and leave a one-line comment saying LazyVim's own window maps cover those keys here.
- Verify `.gitignore` inside `config/nvim/` does not hide any vendored file from devaloy's own git. Its patterns are `tt.*`, `.tests`, `doc/tags`, `debug`, `.repro`, `foo.*`, `*.log`, `data`, so no collision is expected, but confirm with `git status --ignored`.

### Phase 2: seed from the vendored copy in `bootstrap-toolchain.sh` (built 2026-09-08)

- In the `--- LazyVim ---` block, replace `git clone --depth 1 https://github.com/LazyVim/starter` and the `rm -rf .git` that follows it with `cp -R /opt/devaloy/config/nvim/. "${HOME}/.config/nvim/"`.
- Keep the directory guard, the non-fatal behaviour, and the headless `Lazy! sync` warm-up unchanged.
- Rewrite the block comment. The current one explains why the config is a clone and not a copy from `config/`, and that reasoning is now inverted: the copy is guarded, so it seeds once and never overwrites.
- Fall back to the starter clone when `/opt/devaloy/config/nvim` is absent, so an old image with a new bootstrap script still lands an editor.

### Phase 3: add `devaloy-nvim-sync` (built 2026-09-08)

- New executable at the repo root, next to `devaloy-update` and `devaloy-prune`, added to the `COPY --chmod=755` list on Dockerfile:362.
- Behaviour: refuse to run as root (copy `devaloy-update`'s check), back up the current `~/.config/nvim` to `~/.config/nvim.bak-<timestamp>`, copy `/opt/devaloy/config/nvim/.` over it, then run the headless `Lazy! sync`.
- Print the backup path on exit. This is the escape hatch for a box that already holds the starter, including this one.
- Take a `--no-backup` flag for the case where I know the current copy is disposable.

### Phase 4: point `EDITOR` at nvim (built 2026-09-08)

- `config/zsh/zshrc:22` sets `EDITOR=vim` with a comment saying nothing here is worth an editor bootstrap. That is stale: the box now ships a configured Neovim, and `git commit` and `gh` both open `EDITOR`.
- Guard it the same way the `v` alias is guarded at line 104, so a cold volume with no mise-installed nvim still gets vim.
- Update the comment on both.

### Phase 5: document it (built 2026-09-08)

- Add a `devaloy-nvim-sync` row to the command table in `docs/wiki/reference.md`.
- Add a short section to `docs/wiki/getting-started.md` or `reference.md` saying the config is seeded once, where the source is, and how to reset (delete `~/.config/nvim`, `~/.local/share/nvim`, `~/.local/state/nvim`, `~/.cache/nvim`, then run `devaloy-nvim-sync`).
- Note the Navigator divergence, so future-me does not read it as an accidental omission.

### Rejected alternatives

- **Clone `mimukit/dotfiles` at bootstrap.** Keeps one source of truth, but adds a network dependency to the boot path and makes the box handle chezmoi's `dot_` names at runtime.
- **Install chezmoi and apply the nvim path.** Handles the naming natively and opens the door to the rest of my dotfiles, but adds a tool and a templating layer for one directory.
- **Seed through `entrypoint.sh`'s `seed_config()`.** Rejected on mechanism: it overwrites on every boot.

## Open questions

- **Does the system clipboard work here at all?** `options.lua` sets `clipboard = ""` and the `<leader>y` maps write to the `+` register. Over Tailscale SSH there is no X display. Neovim 0.10 and later can fall back to OSC 52 in an SSH session, and this box runs 0.12.5, but I have not confirmed it fires here or that the terminal on the other end accepts it. If it does not, five keymaps are dead weight on devaloy.
- **Is the vendored `lazy-lock.json` a help or a trap?** It pins to commits resolved on the laptop, possibly months old. A plugin that needs a newer Neovim than the pin expects, or a pin older than the LazyVim version mise installs, could fail the first `Lazy! sync`. Worth deciding whether the seed should delete the lockfile and resolve fresh instead.
- **Do the three `lazyvim.json` extras need binaries the image lacks?** `lang.json` and `lang.toml` pull LSP servers through Mason, which downloads at first use. `util.dot` is the dotfiles-filetype extra. Check whether Mason can install them offline-ish over a phone tether, and whether `unzip` (already in the apt list, Dockerfile:144) is all they need.
- **Should the vendored copy carry `.gitignore` at all?** It is a nested gitignore inside devaloy's own tree, which is legal but easy to misread. It only matters once the seeded copy becomes its own repo on the box, which it currently is not.
- **How does this stay in sync with the laptop?** Nothing here notices when `mimukit/dotfiles` changes. Possibly a make target or a documented copy step, possibly nothing at all.

## Non-goals

- Managing devaloy's other dotfiles through chezmoi. This plan covers `~/.config/nvim` only.
- Making devaloy the source of truth for the nvim config. `mimukit/dotfiles` stays canonical; `config/nvim/` is a vendored copy.
- Adding `Navigator.nvim` or tmux pane-navigation bindings.
- Changing which Neovim version mise installs, or the plugin set itself.
- Any two-way sync back from the box to `mimukit/dotfiles`.
