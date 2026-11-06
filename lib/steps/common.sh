#!/usr/bin/env bash
# devaloy boot steps: the variables and helpers every step file shares.
#
# Sourced by entrypoint.sh, never executed. The step files under lib/steps/
# hold the per-boot setup that writes files or runs one-shot commands, as
# functions; entrypoint.sh calls them in order and keeps the process starts
# (tailscaled, dockerd, Paseo, T3 Code) to itself.
#
# Every step reads its inputs from the environment and from the globals below,
# exactly as the inline sections of entrypoint.sh did before the split. The
# steps set globals too (SIGNING_KEY, GIT_EMAIL, PASEO_START_ENV …) that a
# later step or a process block reads, so the call ORDER in entrypoint.sh is
# part of the contract, not a matter of taste.

# The globals below are read by the other step files and by entrypoint.sh,
# which shellcheck cannot see when it checks this file on its own.
# shellcheck disable=SC2034

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"
CONFIG_SRC="/opt/devaloy/config"
# Version pins live in bootstrap-toolchain.sh; these are only forwarded, so an
# empty value here falls through to that script's default.

# The three files the dev shell and the hooks read. ENV_SNIPPET is safe to cat;
# the other two hold credentials and are written 0600.
ENV_SNIPPET="${DEV_HOME}/.devaloy_env"
SECRETS_SNIPPET="${DEV_HOME}/.devaloy_secrets"
PUSH_ENV_FILE="${DEV_HOME}/.config/agent-push.env"

# The suffix of the staging copy a rewrite-from-scratch step builds before
# commit_staged swaps it in. See commit_staged below.
STAGED=".devaloy-new"

# --- the runtime -------------------------------------------------------------
#
# The same steps run in two places: the container entrypoint, and on a native
# VM (scripts/install-native.sh and devaloy-boot.service). Most of them write
# the same files either way. What differs is the advice a step prints when it
# fails: "recover from the Docker host with docker compose exec" is the only
# way back into a container, and a command that does not exist on a VM. So a
# step that prints a recovery hint asks on_native() first and names the
# command for the box it is actually on.
#
# The environment wins, then the RUNTIME key in build-flags, then container.
# The Dockerfile writes RUNTIME=container and the native installer writes
# RUNTIME=native; an image built before the key existed has neither, and it is
# a container, so the fallback is the honest answer rather than a guess. The
# CLI resolves the same key the same way in lib/common.sh (devaloy_runtime).
# That file is not sourced here, because it makes a temp directory and sets an
# EXIT trap the moment it is sourced.
#
# Anything that is not exactly `native` reads as container, so a typo in the
# key keeps the output this script has always printed.
BUILD_FLAGS_FILE="${BUILD_FLAGS_FILE:-/opt/devaloy/build-flags}"
if [ -z "${RUNTIME:-}" ]; then
  RUNTIME="$(sed -n 's/^RUNTIME=//p' "${BUILD_FLAGS_FILE}" 2>/dev/null | head -1 || true)"
fi
[ "${RUNTIME}" = "native" ] || RUNTIME=container

on_native() { [ "${RUNTIME}" = "native" ]; }

# The log prefix. The container keeps [entrypoint], which is the name of the
# script that prints it and the string `docker logs | grep` has always keyed on.
# On a VM no script by that name runs; journalctl already tags each line with
# the unit, so the prefix only has to say which program is talking.
if on_native; then
  LOG_TAG=devaloy
else
  LOG_TAG=entrypoint
fi

log() { echo "[${LOG_TAG}] $*"; }

# Run a command as the dev user under a plain sh. The explicit -s matters now
# that the dev user's login shell is zsh: without it every helper below would
# run through a shell whose startup files this script is in the middle of
# rewriting. -l gives a clean environment and a correct HOME.
as_dev() { su -l -s /bin/sh "${DEV_USER}" -c "$1"; }

# commit_staged NEW DEST — put a freshly built file in place only when it says
# something new.
#
# Several steps rebuild a file from scratch on every boot (the secrets, the
# shell env, the push config, the signing key), because rebuilding is what
# makes clearing a value a real revocation. Rebuilding in place also rewrote
# the file when nothing had changed. On a container that cost nothing anyone
# saw; on a native VM the installer re-runs every boot step, and a re-run must
# leave /home/dev alone when the inputs are the same, so a `find -newer` after
# a second run shows only what really moved. So each such step now builds
# NEW beside DEST and hands both to this function:
#
#   NEW missing        the step decided the file should not exist: DEST goes,
#                      which keeps the revocation contract.
#   NEW same as DEST   NEW goes, and DEST keeps its bytes, owner, mode and
#                      mtime.
#   otherwise          NEW is renamed over DEST, so a reader never sees a
#                      half-written file.
#
# The content of DEST is exactly what the old in-place write produced; only
# the mtime of an unchanged file differs.
commit_staged() {
  local new="$1" dest="$2"
  if [ ! -e "${new}" ]; then
    rm -f "${dest}"
  elif [ -f "${dest}" ] && cmp -s "${new}" "${dest}"; then
    rm -f "${new}"
  else
    mv -f "${new}" "${dest}"
  fi
}

# Appends one export to ~/.devaloy_secrets. See step_secrets for the lifecycle.
write_secret() {
  name="$1"; value="$2"
  [ -n "${value}" ] || return 0
  [ -f "${SECRETS_SNIPPET}" ] || \
    install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SECRETS_SNIPPET}"
  # Single-quote the value and escape any embedded quote, so a token with shell
  # metacharacters cannot execute anything when this file is sourced.
  printf "export %s='%s'\n" "${name}" \
    "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")" >> "${SECRETS_SNIPPET}"
  log "${name} wired into the dev shell environment"
}

# Appends one key to ~/.config/agent-push.env. See step_push_config.
push_write() {
  name="$1"; value="$2"
  [ -n "${value}" ] || return 0
  mkdir -p "${DEV_HOME}/.config"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.config" 2>/dev/null || true
  [ -f "${PUSH_ENV_FILE}" ] || \
    install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${PUSH_ENV_FILE}"
  # Single-quote and escape embedded quotes, so a value with shell
  # metacharacters cannot execute anything when agent-push sources this file.
  printf "%s='%s'\n" "${name}" \
    "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")" >> "${PUSH_ENV_FILE}"
}

# Shell-quote one argument for a string that as_dev hands to `su -c`.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# One `git config --global` key, written as the dev user. git rewrites the
# whole ~/.gitconfig on every `git config` set, even to the value it already
# holds, so the key is read first and an equal value is left alone. See
# commit_staged for why an unchanged file must keep its mtime.
git_cfg() {
  as_dev "[ \"\$(git config --global --get $(sq "$1"))\" = $(sq "$2") ] ||
    git config --global $(sq "$1") $(sq "$2")"
}
# Drop one `git config --global` key; a key that is not set is not an error.
git_unset() { as_dev "git config --global --unset-all $(sq "$1") || true"; }
