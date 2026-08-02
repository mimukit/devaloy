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
TOOLSET_REVISION=3

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
mise install

# Written last, and only on success: a bootstrap that died halfway through must
# leave the volume behind the revision so the next boot retries it.
mkdir -p "$(dirname "${MARKER}")"
printf '%s\n' "${TOOLSET_REVISION}" > "${MARKER}"
