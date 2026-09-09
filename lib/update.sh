#!/usr/bin/env bash
# devaloy: re-seed the managed dotfiles, then re-run the toolchain bootstrap.
#
# Boot-time bootstrap is gated on the toolset revision recorded in the home
# volume, so redeploys are predictable and never re-resolve versions under a
# live session. --force is what makes this the deliberate way to pick up changed
# pins or newer releases of the tools that track latest.
#
# The config seed in entrypoint.sh runs at container start only, so editing a
# file under config/ used to need a redeploy to test. This runs the same seed on
# a live box, which is what --config-only is for: the toolchain half takes
# minutes, and testing a one-line change to config/bin/usage should not.
#
# Usage:
#   devaloy update                 seed the config, then re-run the bootstrap
#   devaloy update --config-only   seed the config and stop, seconds not minutes
#   devaloy update --no-config     the old behaviour, toolchain only
#
# The toolchain half takes minutes and prints a lot, which is why the TUI exits
# before running it rather than paging it: a resolve that is still working looks
# identical to one that has hung when you cannot see it move.

UPDATE_DO_CONFIG=1
UPDATE_DO_TOOLCHAIN=1

update_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --config-only) UPDATE_DO_TOOLCHAIN=0 ;;
      --no-config) UPDATE_DO_CONFIG=0 ;;
      -h | --help)
        sed -n '/^# Usage:/,/^$/p' "${DEVALOY_LIB}/update.sh" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) die "update: unknown argument '${arg}'." ;;
    esac
  done
  [ "${UPDATE_DO_CONFIG}" -eq 1 ] || [ "${UPDATE_DO_TOOLCHAIN}" -eq 1 ] ||
    die "update: --config-only and --no-config together leave nothing to do."
}

# config_src — where the managed dotfiles are read from.
#
# /opt/devaloy/config is baked into the image by a Dockerfile COPY, so on a box
# where the repo is also cloned it is a snapshot of whatever was committed at
# build time. Prefer the clone, because the only reason to run this by hand is
# to test an edit that lives there. DEVALOY_CONFIG_SRC overrides both, for a
# clone somewhere other than the usual path.
config_src() {
  local candidate
  for candidate in \
    "${DEVALOY_CONFIG_SRC:-}" \
    "${HOME}/projects/devaloy/config" \
    /opt/devaloy/config; do
    [ -n "${candidate}" ] && [ -d "${candidate}" ] && printf '%s' "${candidate}" && return 0
  done
  return 1
}

# do_config_seed — the same copy entrypoint.sh runs at boot, on a live box.
#
# Keep this in step with the "managed dotfiles" block of entrypoint.sh. The copy
# MERGES rather than replaces, so files the repo does not ship are left alone:
# ~/.zshrc.local, credentials, session history, skills added by hand. config/nvim
# is not seeded here on purpose — it is seeded once and `devaloy nvim-sync` is
# the deliberate way to overwrite it. config/paseo and config/docker do not
# belong in /home/dev at all.
do_config_seed() {
  local src dest sub
  src="$(config_src)" || die "update: no config directory found to seed from."

  cp -f "${src}/zsh/zshrc" "${HOME}/.zshrc"
  for sub in claude:.claude codex:.codex bin:.local/bin; do
    dest="${HOME}/${sub#*:}"
    [ -d "${src}/${sub%%:*}" ] || continue
    mkdir -p "${dest}"
    cp -R "${src}/${sub%%:*}/." "${dest}/"
  done

  # Same removal entrypoint.sh makes: the delete guard is gone, and a merge copy
  # would otherwise leave the old scripts on the persistent volume forever,
  # unwired but on PATH.
  rm -f "${HOME}/.local/bin/agent-hook" "${HOME}/.local/bin/rm-guard"

  echo "devaloy: config seeded from ${src}"
}

do_update() {
  update_args "$@"
  refuse_root update

  if [ "${UPDATE_DO_CONFIG}" -eq 1 ]; then
    do_config_seed
  fi

  if [ "${UPDATE_DO_TOOLCHAIN}" -eq 0 ]; then
    echo "devaloy: config updated."
    return 0
  fi

  # --force skips the revision gate, so this re-runs the skills install too.
  # That is deliberate and it is the publish loop: push a skill to
  # mimukit/skills, run this, and it is on the box. It has to be `skills add`,
  # which the bootstrap runs — `skills update` only refreshes what is already
  # installed, so it would never notice a skill you authored yesterday.
  /usr/local/bin/bootstrap-toolchain.sh --force

  # Refresh the /usr/local/bin mirror so anything newly installed (including
  # `npm i -g` tools) resolves for non-interactive sessions too — scp, rsync,
  # git-over-ssh and `ssh devaloy '<cmd>'`. This also picks up Claude Code and
  # Codex, which mise installs into the home volume like any other tool — so
  # upgrading them here persists across a redeploy.
  sudo DEV_HOME="${HOME}" /usr/local/bin/link-shims

  echo "devaloy: toolchain updated."
}

# --- the toolchain view ---------------------------------------------------
#
# Two commands that both take minutes and both overwrite something, so they
# share a view and the `a` key routes on the row rather than the view. This is
# the one place a row's value field carries meaning. `do_nvim_sync` lives in
# nvim.sh; the view calls it from here because "update the toolchain" and
# "re-seed the editor config" are the same errand to the person typing it.
rows_tools() {
  emit_head 'toolchain' "toolset $(toolset_revision)"
  emit "$(printf '  🔼  %-22s %s%s%s' 'update the toolchain' "${DIM}" 'seed the config, re-resolve every pin, refresh the shims' "${RESET}")" 'update'
  emit "$(printf '  ⚡  %-22s %s%s%s' 'seed the config only' "${DIM}" 'copy config/ over ~, no toolchain resolve' "${RESET}")" 'config'
  emit "$(printf '  📝  %-22s %s%s%s' 'sync the nvim config' "${DIM}" 'copy config/nvim over ~/.config/nvim, backed up' "${RESET}")" 'nvim'
  emit_hint "${DIM}the first and last take minutes and stream on the terminal${RESET}"
}

tools_apply() { # tools_apply <row value>
  case "$1" in
    update)
      if ! confirm \
        "devaloy update seeds config/ over your dotfiles, then re-runs" \
        "bootstrap-toolchain.sh --force. It re-resolves every pin, so tools" \
        "tracking latest may move. It takes several minutes and prints as it goes."; then
        printf '\n  cancelled\n'
        sleep 1
        return 0
      fi
      run_raw do_update
      ;;
    config)
      if ! confirm \
        "devaloy update --config-only copies config/ over the matching files" \
        "in your home directory: .zshrc, ~/.claude, ~/.codex, ~/.local/bin." \
        "It merges, so files the repo does not ship are left alone."; then
        printf '\n  cancelled\n'
        sleep 1
        return 0
      fi
      run_raw do_update --config-only
      ;;
    nvim)
      if ! confirm \
        "devaloy nvim-sync overwrites ~/.config/nvim with the repo copy." \
        "The current directory is moved to a timestamped .bak- first, so any" \
        "edits you made on this box are recoverable."; then
        printf '\n  cancelled\n'
        sleep 1
        return 0
      fi
      run_raw do_nvim_sync
      ;;
    *)
      printf '\n  that row does nothing\n'
      sleep 1
      ;;
  esac
}
