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
TOOLSET_REVISION=4

MARKER="${HOME}/.local/share/mise/.devaloy-bootstrapped"

case "${1:-}" in
  --force) ;;
  '')
    if [ "$(cat "${MARKER}" 2>/dev/null)" = "${TOOLSET_REVISION}" ]; then
      echo "toolset revision ${TOOLSET_REVISION} already installed, skipping (run devaloy-update to refresh)"
      exit 0
    fi
    ;;
  *)
    echo "bootstrap-toolchain.sh: unknown argument: $1" >&2
    exit 2
    ;;
esac

# Node is pinned to an LTS *major*, not mise's floating `lts` alias — that
# alias rolls across majors, which is exactly the unannounced jump a devbox
# shouldn't take on a redeploy. Bump this deliberately.
MISE_NODE_VERSION="${MISE_NODE_VERSION:-24}"
# herdr tracks latest by design: the boot bootstrap is gated behind the revision
# marker above, so an ordinary redeploy can't swap it under a live session. Set
# MISE_HERDR_VERSION in compose to pin it.
MISE_HERDR_VERSION="${MISE_HERDR_VERSION:-latest}"

echo "installing toolset revision ${TOOLSET_REVISION} — several minutes on a cold volume"

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
mise install

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

# Written last, and only on success: a bootstrap that died halfway through must
# leave the volume behind the revision so the next boot retries it.
mkdir -p "$(dirname "${MARKER}")"
printf '%s\n' "${TOOLSET_REVISION}" > "${MARKER}"
