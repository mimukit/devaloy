#!/usr/bin/env bash
# devaloy boot steps: T3 Code's on-disk setup.
#
# Sourced by entrypoint.sh after common.sh, never executed. The server's
# restart loop stays in entrypoint.sh. The per-boot `t3` upgrade is
# step_t3code_upgrade in lib/steps/toolchain.sh, because it runs with the
# toolchain rather than with the server.

# --- one worktree root for Paseo and T3 Code ---
# T3 Code puts its worktrees under ~/.t3/worktrees, and the stable release
# has no setting to move them. A symlink moves them on every version and
# writes no setting. A real directory there means worktrees already exist
# in it, so it is left alone rather than moved under a live checkout.
step_t3code_config() {
  T3CODE_WT="${DEV_HOME}/.t3/worktrees"
  if [ -L "${T3CODE_WT}" ]; then
    # Already linked. Recreate the target in case ~/worktrees was deleted
    # since, because a dangling link fails every worktree T3 Code creates.
    as_dev "mkdir -p '${DEV_HOME}/worktrees'" || true
  elif [ -e "${T3CODE_WT}" ]; then
    log "T3 Code: ~/.t3/worktrees is a real directory, so its worktrees stay"
    log "T3 Code: there. Move them to ~/worktrees and delete it to share the root."
  elif as_dev "mkdir -p '${DEV_HOME}/worktrees' '${DEV_HOME}/.t3' && \
      ln -s '${DEV_HOME}/worktrees' '${T3CODE_WT}'"; then
    log "T3 Code: ~/.t3/worktrees now points at ~/worktrees"
  else
    log "WARNING: could not link ~/.t3/worktrees to ~/worktrees. T3 Code"
    log "WARNING: keeps its worktrees under ~/.t3 until the next boot."
  fi
}
