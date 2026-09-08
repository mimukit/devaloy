#!/usr/bin/env bash
# devaloy: re-run the toolchain bootstrap.
#
# Boot-time bootstrap is gated on the toolset revision recorded in the home
# volume, so redeploys are predictable and never re-resolve versions under a
# live session. --force is what makes this the deliberate way to pick up changed
# pins or newer releases of the tools that track latest.
#
# Usage: devaloy update
#
# It takes minutes and prints a lot, which is why the TUI exits before running
# it rather than paging it: a resolve that is still working looks identical to
# one that has hung when you cannot see it move.

do_update() {
  [ $# -eq 0 ] || die "update: takes no arguments"
  refuse_root update

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
  emit "  ${BOLD}toolchain${RESET}   ${DIM}toolset $(toolset_revision)${RESET}"
  emit "$(printf '  🔼  %-22s %s%s%s' 'update the toolchain' "${DIM}" 're-resolve every pin, refresh the shims' "${RESET}")" 'update'
  emit "$(printf '  📝  %-22s %s%s%s' 'sync the nvim config' "${DIM}" 'copy config/nvim over ~/.config/nvim, backed up' "${RESET}")" 'nvim'
  emit_rule
  emit "  ${DIM}  both take minutes and stream on the terminal${RESET}"
}

tools_apply() { # tools_apply <row value>
  case "$1" in
    update)
      if ! confirm \
        "devaloy update re-runs bootstrap-toolchain.sh --force." \
        "It re-resolves every pin, so tools tracking latest may move." \
        "It takes several minutes and prints as it goes."; then
        printf '\n  cancelled\n'
        sleep 1
        return 0
      fi
      run_raw do_update
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
