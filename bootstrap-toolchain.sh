#!/usr/bin/env bash
# Installs the devaloy toolchain via mise. Runs as the dev user, never root.
# Shared by entrypoint.sh (first boot) and devaloy-update (deliberate upgrade)
# so the tool list and the pins only ever live in one place.
#
# That one place is config/mise/config.toml, NOT this file. This script seeds
# that config into ~/.config/mise and runs `mise install`; adding or dropping a
# tool is an edit to the TOML and nothing here. What is left below is the work
# a declaration cannot do: the optional keys, the install gate, agent skills,
# the LazyVim seed, the Chromium download, the herdr integrations.
#
# Usage: bootstrap-toolchain.sh [--force]
#   no args   install only if the home volume is behind the declared toolset
#   --force   install regardless — what devaloy-update runs
set -euo pipefail

MARKER="${HOME}/.local/share/mise/.devaloy-bootstrapped"
MISE_CONFIG_DIR="${HOME}/.config/mise"

# The optional tools. Each is a fragment under config/mise/optional/ that lands
# in ~/.config/mise/conf.d/ when its key is true and is DELETED when it is
# false, so turning a key off actually undeclares the tool. mise loads every
# non-hidden TOML in that directory.
WITH_PASEO="${WITH_PASEO:-false}"
WITH_BROWSER="${WITH_BROWSER:-false}"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  '') ;;
  *)
    echo "bootstrap-toolchain.sh: unknown argument: $1" >&2
    exit 2
    ;;
esac

# See entrypoint.sh, which exports this into every shell for the same reason.
# Repeated here because the boot path runs this script under `su -l -s /bin/sh`,
# which sources neither .zshenv nor .bashrc.
export MISE_MINIMUM_RELEASE_AGE=0

# --- where the declared toolset comes from ------------------------------------
# Same order devaloy-update's config_src() uses, and for the same reason:
# /opt/devaloy/config is a build-time snapshot baked in by a Dockerfile COPY, so
# on a box that also has the repo cloned, the clone is the copy you are editing.
# DEVALOY_CONFIG_SRC overrides both.
config_src() {
  local candidate
  for candidate in \
    "${DEVALOY_CONFIG_SRC:-}" \
    "${HOME}/projects/devaloy/config" \
    /opt/devaloy/config; do
    if [ -n "${candidate}" ] && [ -f "${candidate}/mise/config.toml" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

# --- the effective toolset, staged and hashed ---------------------------------
# Rendered into a temp directory BEFORE the install gate, because the gate is
# now the hash of what this run would install: config.toml with the two pin
# variables applied, plus whichever optional fragments the keys turned on.
#
# The hash replaces a hand-bumped TOOLSET_REVISION, and that is the point of the
# whole arrangement. The old number had to be remembered on every tool change,
# and forgetting it left an already-provisioned volume matching a stale marker,
# skipping the script, and never receiving the new tool — which is exactly how
# claude and codex once failed to arrive. A hash cannot forget. It also folds in
# the optional keys, so flipping WITH_PASEO invalidates the marker by itself.
#
# Re-running is close to free: the boot path runs `mise install`, never
# `mise upgrade`, so every tool already on the volume stays where it is.
#
# The agent skills at the end of this script sit behind the same marker. That
# stops an ordinary redeploy re-resolving them mid-session; it is NOT how a
# newly authored skill reaches the box. `devaloy-update` (or `skmi`) runs
# --force and skips the gate, so publishing a skill needs no edit here.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/conf.d"

CONFIG_SRC="$(config_src || true)"
if [ -z "${CONFIG_SRC}" ]; then
  # An image built before config/mise/ existed, with no clone to read either.
  # The declared set is then whatever is already in the home volume: install it
  # rather than aborting, and say why the box is not tracking the repo.
  if [ ! -f "${MISE_CONFIG_DIR}/config.toml" ]; then
    echo "bootstrap-toolchain.sh: no mise config found in the image, the clone" >&2
    echo "bootstrap-toolchain.sh: or ${MISE_CONFIG_DIR}. Nothing to install." >&2
    exit 1
  fi
  echo "WARNING: no config/mise/config.toml to seed from — keeping the copy in" >&2
  echo "WARNING: ${MISE_CONFIG_DIR}. Pull the repo and run devaloy-update." >&2
  cp "${MISE_CONFIG_DIR}/config.toml" "${STAGE}/config.toml"
  SEED=0
else
  cp "${CONFIG_SRC}/mise/config.toml" "${STAGE}/config.toml"
  SEED=1
fi

# The two pin variables from compose, applied to the staged copy rather than
# left in the environment. mise does read MISE_<TOOL>_VERSION as an override,
# but only in a process that HAS it — the boot path would install one version
# and every later shell would read another out of the config. Writing the pin
# into the file keeps one answer for the whole box.
#
# Only when set and non-empty. entrypoint.sh forwards these unconditionally, so
# an unset key arrives as the empty string, and `node = ""` is not a version.
#
# There is no equivalent for Paseo, and the reason is a name collision rather
# than a policy call: mise reads any MISE_<TOOL>_VERSION in its environment as
# "add tool <TOOL> at this version", so a MISE_PASEO_VERSION declared a tool
# literally named `paseo`. There is no `paseo` in mise's registry — the package
# is npm:@getpaseo/cli — so every mise call warned and exited 1, which under
# `set -e` killed this script before the marker, the skills and the herdr
# integrations. `node` and `herdr` are safe from that trap only because both ARE
# registry entries. To hold Paseo, edit the pin in optional/paseo.toml.
pin_tool() {
  local tool="$1" version="$2"
  [ -n "${version}" ] || return 0
  if ! grep -qE "^${tool} = " "${STAGE}/config.toml"; then
    echo "WARNING: no '${tool}' line in config.toml — pin ignored." >&2
    return 0
  fi
  sed -i "s|^${tool} = .*|${tool} = \"${version}\"|" "${STAGE}/config.toml"
  echo "pinned ${tool} to ${version} from the environment"
}
pin_tool node "${MISE_NODE_VERSION:-}"
pin_tool herdr "${MISE_HERDR_VERSION:-}"

if [ "${SEED}" -eq 1 ]; then
  if [ "${WITH_PASEO}" = "true" ]; then
    cp "${CONFIG_SRC}/mise/optional/paseo.toml" "${STAGE}/conf.d/paseo.toml"
  fi
  if [ "${WITH_BROWSER}" = "true" ]; then
    cp "${CONFIG_SRC}/mise/optional/browser.toml" "${STAGE}/conf.d/browser.toml"
  fi
fi

# One hash over every staged file, names included, so a fragment appearing or
# disappearing moves the marker as surely as an edited pin does.
MARKER_VALUE="$(cd "${STAGE}" && find . -name '*.toml' -type f | sort |
  xargs sha256sum | sha256sum | cut -c1-12)"

if [ "${FORCE}" -eq 0 ] &&
  [ "$(cat "${MARKER}" 2>/dev/null)" = "${MARKER_VALUE}" ]; then
  echo "toolset ${MARKER_VALUE} already installed, skipping (run devaloy-update to refresh)"
  exit 0
fi

echo "installing toolset ${MARKER_VALUE} — several minutes on a cold volume"

if [ ! -x "${HOME}/.local/bin/mise" ]; then
  curl -fsSL https://mise.run | sh
fi
export PATH="${HOME}/.local/bin:${PATH}"

# --- seed the declared toolset ------------------------------------------------
# The staged copy from the top of this script, moved into place. A merge would
# be wrong here: ~/.config/mise/config.toml is the repo's file, and a `mise use`
# you ran on the box is meant to be overwritten by it. conf.d is pruned to the
# staged fragments for the same reason — that is what makes WITH_PASEO=false
# undeclare Paseo instead of leaving the last true value on the volume forever.
#
# Skipped entirely when there was nothing to seed from; the warning is already
# printed above and the config in the home volume is what gets installed.
if [ "${SEED}" -eq 1 ]; then
  mkdir -p "${MISE_CONFIG_DIR}/conf.d"
  cp "${STAGE}/config.toml" "${MISE_CONFIG_DIR}/config.toml"
  rm -f "${MISE_CONFIG_DIR}/conf.d/paseo.toml" \
    "${MISE_CONFIG_DIR}/conf.d/browser.toml"
  for fragment in "${STAGE}"/conf.d/*.toml; do
    [ -f "${fragment}" ] || continue
    cp "${fragment}" "${MISE_CONFIG_DIR}/conf.d/$(basename "${fragment}")"
  done
  echo "mise config seeded from ${CONFIG_SRC}/mise"
fi

mise install

# `mise install` does NOT move a tool that is already installed, even one pinned
# to `latest` — it resolves `latest` against what is on disk, prints "all tools
# are installed" and stops. Every `latest` tool in the config was therefore
# frozen at whatever version first landed on the home volume, and devaloy-update
# upgraded nothing. `mise upgrade` is the command that actually re-resolves.
#
# Only on --force. The boot path must stay install-only: the toolset marker
# exists precisely so a redeploy cannot swap an agent CLI under a live session,
# and upgrading here would hand that back. No --bump — that would rewrite the
# pins in the seeded config to concrete versions, defeating `latest` and putting
# the copy in the home volume out of step with the repo's.
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

# --- the CodeRabbit CLI ------------------------------------------------------
# `coderabbit review` runs an AI code review over the working tree from the
# terminal, and `--prompt-only` gives an agent on this box a findings list to
# act on. It is not a mise tool: there is no registry entry and no npm package,
# so it comes from CodeRabbit's own install script, which drops the binary and
# its `cr` alias into ~/.local/bin — the home volume, so it survives a redeploy.
#
# CI=1 is what keeps this safe to run unattended. Without it the installer ends
# with an interactive login prompt, and on a headless box that prompt is a boot
# that never finishes. Authentication happens elsewhere: entrypoint.sh stores
# CODERABBIT_API_KEY with `cr auth login --api-key` once the binary is on PATH.
# A browser login is the only other route, and there is no browser here.
#
# The installer appends a PATH line to a shell profile only when ~/.local/bin is
# missing from one, and entrypoint.sh has already put it there, so on this box it
# writes nothing (verified: no CodeRabbit line in ~/.zshrc after a run).
#
# Pinned by CODERABBIT_VERSION when set; empty means latest. config/mise/config.toml
# carries the declaration that moves the install marker — see the comment there.
#
# Non-fatal, like the herdr block below. A box with no reviewer CLI is still a
# working box, and an outage at CodeRabbit's CDN must not cost the volume its
# marker and re-run the whole toolset install on the next boot.
echo "installing the CodeRabbit CLI"
if CI=1 CODERABBIT_VERSION="${CODERABBIT_VERSION:-}" \
  sh -c 'curl -fsSL https://cli.coderabbit.ai/install.sh | sh' >/dev/null 2>&1; then
  echo "coderabbit installed at ${HOME}/.local/bin/coderabbit"
else
  echo "WARNING: the CodeRabbit CLI install failed. Re-run devaloy-update, or" >&2
  echo "WARNING: run the installer by hand. Nothing else is affected." >&2
fi

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
# leave the volume behind the declared toolset so the next boot retries it.
mkdir -p "$(dirname "${MARKER}")"
printf '%s\n' "${MARKER_VALUE}" > "${MARKER}"
