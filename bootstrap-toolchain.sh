#!/usr/bin/env bash
# Installs the devaloy toolchain via mise. Runs as the dev user, never root.
# Shared by entrypoint.sh (first boot) and devaloy-update (deliberate upgrade)
# so the tool list and the pins only ever live in one place.
#
# Usage: bootstrap-toolchain.sh [--force]
#   no args   install only if the home volume is behind TOOLSET_REVISION
#   --force   install regardless — what devaloy-update runs
set -euo pipefail

# Bump this whenever the tool list below changes. The marker in the home volume
# records the revision it installed, and the boot path re-runs when the two
# disagree — so an existing box picks up a newly added tool on its next
# redeploy. A marker that only recorded *that* the bootstrap had run is what
# left every already-provisioned volume without claude and codex when they were
# added: the gate saw the marker, skipped, and the tools never arrived.
#
# Bumping does re-resolve the @latest tools, so it can move herdr or an agent
# CLI under a live session. That is the cost of a deliberate toolset change;
# leave this alone for edits that do not add or remove a tool.
#
# The agent skills installed at the end of this script are covered by the same
# marker. Note what that does and does not gate: it stops an ordinary redeploy
# re-resolving skills mid-session, but it is NOT how a newly authored skill
# reaches the box. That is `devaloy-update` (or `skmi`), which runs --force and
# skips the gate entirely — so publishing a skill needs no edit here.
TOOLSET_REVISION=6

MARKER="${HOME}/.local/share/mise/.devaloy-bootstrapped"

# The optional tools (see the blocks further down). Read up here because the
# marker has to know about them: a revision number alone cannot express an
# optional tool, so a volume already at revision N would skip this script
# forever and WITH_PASEO=true would never install anything. Same class of bug as
# the one described above, where claude and codex arrived on a volume whose
# marker already said "done".
#
# So the marker records each FLAG as well as the revision, in a fixed order —
# `5`, `5+paseo`, `5+browser` or `5+paseo+browser` — and flipping either key
# invalidates it. A volume that already reads `5+paseo` still matches, so adding
# a flag here never re-runs a box that did not ask for it. Re-running is close
# to free: the boot path below runs `mise install`, never `mise upgrade`, so
# every tool already on the volume stays exactly where it is.
WITH_PASEO="${WITH_PASEO:-false}"
WITH_BROWSER="${WITH_BROWSER:-false}"
MARKER_VALUE="${TOOLSET_REVISION}"
if [ "${WITH_PASEO}" = "true" ]; then
  MARKER_VALUE="${MARKER_VALUE}+paseo"
fi
if [ "${WITH_BROWSER}" = "true" ]; then
  MARKER_VALUE="${MARKER_VALUE}+browser"
fi

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  '')
    if [ "$(cat "${MARKER}" 2>/dev/null)" = "${MARKER_VALUE}" ]; then
      echo "toolset ${MARKER_VALUE} already installed, skipping (run devaloy-update to refresh)"
      exit 0
    fi
    ;;
  *)
    echo "bootstrap-toolchain.sh: unknown argument: $1" >&2
    exit 2
    ;;
esac

# See entrypoint.sh, which exports this into every shell for the same reason.
# Repeated here because the boot path runs this script under `su -l -s /bin/sh`,
# which sources neither .zshenv nor .bashrc.
export MISE_MINIMUM_RELEASE_AGE=0

# Node is pinned to an LTS *major*, not mise's floating `lts` alias — that
# alias rolls across majors, which is exactly the unannounced jump a dev box
# shouldn't take on a redeploy. Bump this deliberately.
MISE_NODE_VERSION="${MISE_NODE_VERSION:-24}"
# herdr tracks latest by design: the boot bootstrap is gated behind the revision
# marker above, so an ordinary redeploy can't swap it under a live session. Set
# MISE_HERDR_VERSION in compose to pin it.
MISE_HERDR_VERSION="${MISE_HERDR_VERSION:-latest}"
# Paseo has NO pin variable, on purpose, and the reason is a name collision
# rather than a policy call. mise reads any MISE_<TOOL>_VERSION in its
# environment as "add tool <TOOL> at this version", so a MISE_PASEO_VERSION
# here declared a tool literally named `paseo`. There is no `paseo` in mise's
# registry — the package is npm:@getpaseo/cli — so every mise call below warned
# and `mise use` exited 1, which under `set -e` killed this script before the
# marker, the skills install and the herdr integrations. herdr and node are safe
# from the same trap only because `herdr` and `node` ARE registry entries.
#
# So Paseo always tracks latest. That is what the flag was defaulted to anyway,
# and the revision marker above still stops a redeploy swapping it under a live
# session. To hold a version, edit the pin on the `mise use` line below.

echo "installing toolset ${MARKER_VALUE} — several minutes on a cold volume"

if [ ! -x "${HOME}/.local/bin/mise" ]; then
  curl -fsSL https://mise.run | sh
fi
export PATH="${HOME}/.local/bin:${PATH}"

mise use -g "node@${MISE_NODE_VERSION}"
mise use -g pnpm@latest
mise use -g gh@latest
mise use -g npm:turbo@latest
# lazygit has no noble package, so it comes from here instead of the Dockerfile.
# A full-screen git UI is the difference between reviewing a diff over a phone
# tether and giving up on it.
mise use -g lazygit@latest
# Neovim, for the LazyVim config installed further down. Noble ships 0.9.5 and
# LazyVim needs >= 0.11.2, so this comes from mise rather than the apt list in
# the Dockerfile. Its search binaries (ripgrep, fd, unzip) DO come from apt —
# they are system packages with no version demand behind them.
mise use -g neovim@latest
# The tree-sitter CLI, which `:checkhealth lazyvim` reports as an error without.
# nvim-treesitter needs it to build a grammar that ships no prebuilt parser.
mise use -g tree-sitter@latest
mise use -g "herdr@${MISE_HERDR_VERSION}"
# The AI agents. mise's registry entries fetch the same upstream artifacts their
# own installers do — Claude Code's binary checksummed against the release
# manifest, Codex's musl build from its GitHub release — so there is nothing to
# hand-roll here. Both track latest, like pnpm/gh/turbo: pin one by pinning it
# in this file. They ship far too often to freeze by default, and the
# revision marker already stops a redeploy swapping them mid-session.
mise use -g claude@latest
mise use -g codex@latest
# The skills.sh CLI, which installs the agent skills below. It is a tool like
# any other here, so it lands in the home volume and survives a redeploy.
mise use -g npm:skills@latest

# --- OPTIONAL: the Paseo daemon (WITH_PASEO). BEGIN ---------------------------
# One contiguous block, so removing Paseo later is deleting a unit rather than
# unpicking a line from the list above.
#
# It lives HERE and not in the Dockerfile — the opposite of Orca — because it is
# a plain npm package with npm dependencies. No system package, no apt
# resolution, no architecture to match. That means the key is a runtime variable
# and not a build argument: the payload lands in the home volume, so
# `docker compose up -d` is enough to turn it on. Nothing enters the image.
#
# Turning the key back off stops the daemon (see entrypoint.sh); it does NOT
# uninstall this. A `paseo` with no daemon behind it does nothing, and pulling a
# tool out from under a live session is worse than leaving a dormant command on
# PATH.
if [ "${WITH_PASEO}" = "true" ]; then
  mise use -g npm:@getpaseo/cli@latest
fi
# --- OPTIONAL: the Paseo daemon. END ------------------------------------------

# --- OPTIONAL: headless browser capture (WITH_BROWSER). BEGIN -----------------
# The npm half of the feature; the Dockerfile block of the same name holds the
# shared libraries. `playwright-cli` is a plain npm package, so it lands in the
# home volume like Paseo does, and the same key that built the libraries into
# the image is what turns this on. Turning it back off uninstalls nothing, for
# the same reason as Paseo. The browser download is further down, after
# `mise install` has put the CLI on the shims path.
#
# PINNED, unlike Paseo, and not by choice. Releases 0.1.0 through 0.1.18 carry
# npm provenance from GitHub Actions; 0.1.19 (2026-09-01) was published by hand
# from Microsoft's npm account with none. mise's npm backend treats that as a
# trust downgrade and refuses `@latest` outright. This is the newest release
# with provenance. Move the pin by hand once a later release carries it again
# (`npm view @playwright/cli@<v> dist.attestations`), rather than adding a
# trust-policy exclusion or shelling out to npm, which would waive the check
# for every release that follows.
if [ "${WITH_BROWSER}" = "true" ]; then
  mise use -g npm:@playwright/cli@0.1.18
fi
# --- OPTIONAL: headless browser capture. END ----------------------------------

mise install

# `mise install` does NOT move a tool that is already installed, even one pinned
# to `latest` — it resolves `latest` against what is on disk, prints "all tools
# are installed" and stops. Every @latest tool above was therefore frozen at
# whatever version first landed on the home volume, and devaloy-update upgraded
# nothing. `mise upgrade` is the command that actually re-resolves.
#
# Only on --force. The boot path must stay install-only: the revision marker
# exists precisely so a redeploy cannot swap an agent CLI under a live session,
# and upgrading here would hand that back. No --bump — that would rewrite the
# pins above to concrete versions and defeat tracking latest at all.
if [ "${FORCE}" -eq 1 ]; then
  echo "upgrading tools that track latest"
  mise upgrade
fi

# --- agent skills -----------------------------------------------------------
# Skills are NOT shipped in config/ like the rest of the agent setup. They live
# in their own repo and are installed from it by the skills.sh CLI, which is
# what keeps this box and a laptop on the same skills instead of forking a
# vendored copy the day after it landed.
#
# Everything in the repo, deliberately — `--skill '*'`, no curated list. Skill
# authoring is iterative, and a kit you are still shaping is exactly the one you
# want to reach from a phone. Curating would mean editing this file on every
# experiment, which is enough friction to stop it happening.
#
# `-a` is repeated per agent and the Claude target is `claude-code`, not
# `claude`. `--all` would be shorthand for `-a '*'`, but that also writes to
# ~/.cursor, ~/.gemini and other agents this box does not have.
#
# Allowed to be fatal, like every step above it. `set -e` aborts here, the
# marker below is never written, and the next boot retries — which is what you
# want from a network call to GitHub. Catching the failure instead would write
# the marker and leave a box that has every tool, no skills, and no intention of
# trying again. entrypoint.sh already treats a failed bootstrap as non-fatal for
# the box itself, so a skills outage costs you a retry, never your tailnet.
#
# mise's shims are what put `skills` on PATH, and this script has only ever
# exported ~/.local/bin. Without this line the command below is a silent
# "command not found" on every cold boot.
export PATH="${HOME}/.local/share/mise/shims:${PATH}"

echo "installing agent skills from mimukit/skills"
skills add mimukit/skills --global --skill '*' -a claude-code -a codex -y

# --- LazyVim ----------------------------------------------------------------
# The LazyVim config in config/nvim/, copied into the home volume. It is a
# vendored copy of mimukit/dotfiles:dot_config/nvim, so a fresh box gives the
# same editor as the laptop instead of upstream's blank starter.
#
# The copy is SEED-ONCE, and that is the whole reason it lives here rather than
# in entrypoint.sh's seed_config(). That helper is a merge copy that runs on
# every boot, which would overwrite your own lua/config and lua/plugins each
# redeploy. This block is guarded on the directory instead, so --force cannot
# blow away a config you have changed. Once seeded, ~/.config/nvim is yours: edit
# it on the box and it survives every `docker compose up --build`.
#
# To pull the repo copy back over it later, run devaloy-nvim-sync — it backs the
# current directory up first. To start over completely, delete ~/.config/nvim
# (plus the ~/.local/share/nvim, ~/.local/state/nvim and ~/.cache/nvim state
# directories) and run devaloy-update.
#
# Non-fatal, like the herdr block below and unlike the skills install. A box
# with no editor config still has vim from the apt list, and it is not worth
# costing the volume its revision marker.
NVIM_CONFIG_SRC="/opt/devaloy/config/nvim"
if [ ! -d "${HOME}/.config/nvim" ]; then
  nvim_seeded=""
  if [ -d "${NVIM_CONFIG_SRC}" ]; then
    echo "seeding ~/.config/nvim from ${NVIM_CONFIG_SRC}"
    # The trailing /. copies the directory's contents, dotfiles included —
    # .neoconf.json and .gitignore are both part of the config.
    if mkdir -p "${HOME}/.config/nvim" &&
      cp -R "${NVIM_CONFIG_SRC}/." "${HOME}/.config/nvim/"; then
      nvim_seeded="yes"
    else
      echo "WARNING: the nvim config copy failed. Re-run devaloy-update." >&2
    fi
  else
    # An image built before config/nvim/ existed, running a newer copy of this
    # script from the home volume. Upstream's starter still beats no editor.
    echo "${NVIM_CONFIG_SRC} is missing — falling back to the LazyVim starter"
    if git clone --depth 1 https://github.com/LazyVim/starter "${HOME}/.config/nvim"; then
      # The starter's own git history is the starter's, not yours. Upstream's
      # install steps delete it so the directory is free to become your repo.
      rm -rf "${HOME}/.config/nvim/.git"
      nvim_seeded="yes"
    else
      echo "WARNING: the LazyVim starter clone failed. Re-run devaloy-update." >&2
    fi
  fi
  if [ -n "${nvim_seeded}" ]; then
    # Resolve the plugins now instead of on your first `nvim`. Over a phone
    # tether, a cold Lazy sync in the foreground is a minute of a blank screen.
    if ! nvim --headless "+Lazy! sync" +qa 2>&1 | tail -5; then
      echo "WARNING: the first Lazy sync failed — run it again inside nvim." >&2
    fi
  fi
else
  echo "~/.config/nvim exists, leaving it alone"
fi

# --- the Chromium binary (only when WITH_BROWSER=true) -----------------------
# Here rather than in the WITH_BROWSER block above because it needs the CLI
# that `mise install` has only just put on the shims path. `install-browser` is
# Playwright's own `install` command under an alias, and its behaviour is why
# there is no guard around it and no prune after it:
#
#   - It returns at once when the build it wants is already on the volume, so
#     an ordinary redeploy costs nothing. A hand-written "skip if the directory
#     exists" would be wrong: each @playwright/cli release wants its own Chromium
#     revision, so after a devaloy-update the directory exists AND a download is
#     needed.
#   - It removes builds that no installed Playwright links to, so the volume
#     does not grow by one Chromium per update.
#
# `chromium` is both builds, Chrome for Testing and the headless shell, and
# both are needed: with PLAYWRIGHT_MCP_BROWSER=chromium (see entrypoint.sh)
# Playwright launches the full build even headless, so `--only-shell` would
# leave a browser that cannot start. Measured on arm64: 982 MB in
# ~/.cache/ms-playwright (642 MB Chromium, 337 MB headless shell, 3 MB
# Playwright's ffmpeg), 330 s on a cold volume, 1 s when already present. It is
# the home volume, so it survives a redeploy.
#
# Fatal, like the skills install above: a half-downloaded browser must not
# write the marker below, and the next boot retries.
if [ "${WITH_BROWSER}" = "true" ]; then
  echo "installing the Playwright Chromium build"
  playwright-cli install-browser chromium
fi

# --- herdr agent-state integrations -----------------------------------------
# What makes a herdr pane show working/idle instead of nothing. herdr installs
# and versions these scripts itself (`herdr integration status` reports the
# version per agent), so they are NOT vendored into config/ — a copy in this
# repo would freeze one version and need re-copying after every herdr upgrade.
# Running it here means a herdr upgrade re-installs the matching integration on
# the next devaloy-update, with nothing to maintain.
#
# The scripts land in ~/.claude/hooks/ and ~/.codex/ inside the home volume; the
# SessionStart entries that *call* them are ours, in config/claude/settings.json
# and config/codex/hooks.json, because this repo overwrites both files on every
# boot and would otherwise drop whatever herdr wired up.
#
# Non-fatal, unlike the skills install: a missing pane indicator is cosmetic,
# and it is not worth costing the volume its revision marker.
for _target in claude codex; do
  if herdr integration install "${_target}" >/dev/null 2>&1; then
    echo "herdr integration installed for ${_target}"
  else
    echo "WARNING: herdr integration install ${_target} failed — panes will not" >&2
    echo "WARNING: show agent state. Re-run it by hand; nothing else is affected." >&2
  fi
done
unset _target

# Written last, and only on success: a bootstrap that died halfway through must
# leave the volume behind the revision so the next boot retries it.
mkdir -p "$(dirname "${MARKER}")"
printf '%s\n' "${MARKER_VALUE}" > "${MARKER}"
