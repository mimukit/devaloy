#!/usr/bin/env bash
# devaloy: the root view, and the plain-text answer to "how is this box".
#
# This is what `devaloy` opens on, and what it prints when there is no terminal
# to draw a picker in. `ssh devaloy 'devaloy'` and a cron line both land here,
# which makes this block the one thing an agent can grep — the capability
# checks CLAUDE.md currently spells out in prose.
#
# Every reading is cheap: a df, four cgroup files, one pgrep and one head of a
# marker file. That is what lets it refresh on `r` and on return from an action
# without a timer.

status_disk_line() {
  # `df -h` on the home volume, which is the number that matters: /home/dev is
  # the named volume, and everything outside it is thrown away on the next
  # rebuild anyway.
  df -h "${HOME:-/home/dev}" 2>/dev/null | tail -1 |
    awk '{printf "%s used of %s (%s), %s free", $3, $2, $5, $4}'
}

status_ram_line() {
  local cur max pct
  cur="$(read_cg memory.current)"
  max="$(read_cg memory.max)"
  if [ -z "${cur}" ]; then
    printf 'no cgroup v2 accounting readable'
    return
  fi
  pct="$(mem_percent)"
  if [ -n "${pct}" ]; then
    printf '%s of %s (%s%%)' "$(human "${cur}")" "$(human "${max}")" "${pct}"
  else
    # Worth saying rather than printing a bare number: with no mem_limit the
    # container can take the host down, and the figure alone reads as healthy.
    printf '%s, NO mem_limit set' "$(human "${cur}")"
  fi
}

status_swap_line() {
  local swap swapmax
  swap="$(read_cg memory.swap.current)"
  swapmax="$(read_cg memory.swap.max)"
  [ -n "${swap}" ] || { printf 'not readable'; return; }
  printf '%s of %s' "$(human "${swap}")" "$(human "${swapmax}")"
}

status_paseo_line() {
  local roots pids
  roots="$(paseo_pids)"
  if [ -z "${roots}" ]; then
    # WITH_PASEO is exported into interactive shells by entrypoint.sh but not
    # into `ssh devaloy '<cmd>'`, so its absence does not mean Paseo is off.
    # Say what was observed and let the variable qualify it.
    if [ "${WITH_PASEO:-false}" = "true" ]; then
      printf 'DOWN — WITH_PASEO is on but no daemon is running'
    else
      printf 'not running'
    fi
    return
  fi
  pids="$(paseo_tree "${roots}")"
  printf 'up, %s MiB across %s process(es)' \
    "$(paseo_rss_mib "${pids}")" "$(printf '%s\n' "${pids}" | wc -l | tr -d ' ')"
}

status_docker_line() {
  case "$(build_flag WITH_DOCKER)" in
    true)
      if docker info >/dev/null 2>&1; then
        docker system df 2>/dev/null | awk '/^Images/ {print $4 " in images"}' | head -1
      else
        printf 'built in, but the daemon is NOT reachable'
      fi
      ;;
    false) printf 'not built with WITH_DOCKER' ;;
    *) docker info >/dev/null 2>&1 && printf 'daemon up' || printf 'no daemon' ;;
  esac
}

# --- the view -------------------------------------------------------------

rows_status() {
  emit "  ${BOLD}this box${RESET}   ${DIM}read at $(now_stamp)${RESET}"
  emit_row '💾' 'disk (home volume)' "$(status_disk_line)"
  emit_row '🧠' 'ram (cgroup)' "$(status_ram_line)"
  emit_row '💤' 'swap' "$(status_swap_line)"
  emit_row '🪟' 'paseo daemon' "$(status_paseo_line)"
  emit_row '🐳' 'docker' "$(status_docker_line)"
  emit_row '🔧' 'toolset' "$(toolset_revision)"
  emit_rule
  emit_branch '🧹' 'disk reclaim' 'node_modules, mise versions, worktrees, logs' 'disk'
  emit_branch '🔄' 'ram reclaim' 'restart Paseo, reap orphaned language servers' 'ram'
  emit_branch '🐳' 'docker reclaim' 'build cache and unused images' 'prune'
  emit_branch '🔧' 'toolchain' 'update the toolchain, re-seed the nvim config' 'tools'
  emit_branch '🩺' 'doctor' 'what this box was built with, and what is broken' 'doctor'
}

# --- the plain-text mode --------------------------------------------------
#
# No TTY means print this and exit 0. The ip script does the same thing with the
# public IPv4: the caller asked a question, so answer it rather than complaining
# about the absence of a terminal.
do_status() {
  printf 'devaloy: this box, read at %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '  disk    %s\n' "$(status_disk_line)"
  printf '  ram     %s\n' "$(status_ram_line)"
  printf '  swap    %s\n' "$(status_swap_line)"
  printf '  paseo   %s\n' "$(status_paseo_line)"
  printf '  docker  %s\n' "$(status_docker_line)"
  printf '  toolset %s\n' "$(toolset_revision)"
}
