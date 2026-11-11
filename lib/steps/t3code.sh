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

# --- ~/projects as T3 Code projects ---
# Each top-level directory in ~/projects becomes a T3 Code project, so a box
# whose DEVALOY_REPOS clones land there opens with them listed. Hidden
# directories are skipped. `t3 project add` writes the T3 database itself and
# works with or without a running server.
#
# ~/.t3/devaloy-projects records every path this step has handled, one per
# line. A recorded path is never added again, so a project removed in T3 stays
# removed: `t3 project add` accepts a path whose project was removed. A path
# T3 already holds (added by hand) fails with ProjectAlreadyExistsError, which
# counts as done and is recorded. Any other failure logs a warning, is not
# recorded, and is tried again on the next boot.
step_t3code_projects() {
  local dir="${DEV_HOME}/projects" record="${DEV_HOME}/.t3/devaloy-projects" path out
  [ -d "${dir}" ] || return 0
  if ! as_dev "mkdir -p $(sq "${DEV_HOME}/.t3") && touch $(sq "${record}")"; then
    log "WARNING: could not write ${record}. T3 Code: ~/projects is not added"
    log "WARNING: as projects until the next boot."
    return 0
  fi
  for path in "${dir}"/*/; do
    [ -d "${path}" ] || continue
    path="${path%/}"
    if grep -qxF -- "${path}" "${record}"; then
      continue
    fi
    if out="$(as_dev "t3 project add $(sq "${path}")" 2>&1)"; then
      log "T3 Code: added ~/projects/${path##*/} as a project"
    elif ! printf '%s' "${out}" | grep -q 'ProjectAlreadyExistsError'; then
      log "WARNING: T3 Code: could not add ~/projects/${path##*/} as a project."
      log "WARNING: run 't3 project add ${path}' to see why. The next boot tries again."
      continue
    fi
    as_dev "printf '%s\n' $(sq "${path}") >> $(sq "${record}")" || true
  done
}

# --- the environment label ---
# T3 Code names this box in its apps and in `t3 environment list` on the
# other boxes. It reads PRETTY_HOSTNAME from /etc/machine-info first and falls
# back to the system hostname, which on a VM is the provider's name (for
# example instabox-devaloy-insta). The tailnet name is the one the human uses,
# so the label is set to TS_HOSTNAME. The file is written directly, not with
# `hostnamectl --pretty`, because the container runs no systemd-hostnamed.
# Other keys in the file are kept. The container loses /etc on a rebuild, so
# this runs on every boot. The server reads the label when it starts, so this
# runs before the server.
step_t3code_label() {
  local label="${TS_HOSTNAME:-devaloy}" file=/etc/machine-info tmp
  if [ -f "${file}" ] && grep -qx "PRETTY_HOSTNAME=\"${label}\"" "${file}"; then
    return 0
  fi
  tmp="$(mktemp)"
  if { if [ -f "${file}" ]; then grep -v '^PRETTY_HOSTNAME=' "${file}" || true; fi
       printf 'PRETTY_HOSTNAME="%s"\n' "${label}"; } > "${tmp}" \
      && install -m 0644 "${tmp}" "${file}"; then
    log "T3 Code: the environment label is now ${label}"
  else
    log "WARNING: could not write ${file}. T3 Code labels this box with its"
    log "WARNING: hostname until the next boot."
  fi
  rm -f "${tmp}"
}
