#!/usr/bin/env bash
# Installs the devaloy toolchain via mise. Runs as the dev user, never root.
# Shared by entrypoint.sh (first boot) and devaloy-update (deliberate upgrade)
# so the tool list and the pins only ever live in one place.
set -euo pipefail

# Node is pinned to an LTS *major*, not mise's floating `lts` alias — that
# alias rolls across majors, which is exactly the unannounced jump a devbox
# shouldn't take on a redeploy. Bump this deliberately.
MISE_NODE_VERSION="${MISE_NODE_VERSION:-24}"
# herdr tracks latest by design: the boot bootstrap is gated behind a marker,
# so a redeploy can't swap it under a live session. Set MISE_HERDR_VERSION in
# compose to pin it.
MISE_HERDR_VERSION="${MISE_HERDR_VERSION:-latest}"

if [ ! -x "${HOME}/.local/bin/mise" ]; then
  curl -fsSL https://mise.run | sh
fi
export PATH="${HOME}/.local/bin:${PATH}"

mise use -g "node@${MISE_NODE_VERSION}"
mise use -g pnpm@latest
mise use -g gh@latest
mise use -g npm:turbo@latest
mise use -g "herdr@${MISE_HERDR_VERSION}"
mise install
