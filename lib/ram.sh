#!/usr/bin/env bash
# devaloy: reclaim RAM inside this box, by hand.
#
# Written for the two-boxes-on-one-VPS shape, where each container runs under a
# mem_limit and the cgroup OOM killer is the thing you are trying not to meet.
# The point is to give back the memory that long-lived supervisors accumulate
# BEFORE the ceiling fires, so you lose a daemon you can restart instead of an
# agent session halfway through a turn.
#
# REPORTS BY DEFAULT. Nothing is killed until you pass --apply. That is the same
# contract scripts/host-resource-guard.sh uses, and for the same reason: the
# things worth killing here look a lot like the things worth keeping.
#
# What it will NOT do, on purpose:
#
#   drop_caches   `echo 3 > /proc/sys/vm/drop_caches` is NOT namespaced. Writing
#                 it from this container drops the page cache of the WHOLE HOST,
#                 including the databases behind somebody's live site. The
#                 reclaimed number looks great and the cost lands on a neighbour.
#   dev servers   A `next dev` or a `vite` holding 800 MB is usually a server
#                 you are still using. They are reported, never killed. Stop
#                 them yourself.
#
# Usage: devaloy ram [--apply] [--paseo] [--orphans] [--age <minutes>]
#   --apply          actually restart and kill. Without it, this only reports.
#   --paseo          only the Paseo daemon restart
#   --orphans        only the orphaned language-server reap
#   --age <minutes>  an orphan must be idle this long to qualify. Default 60.
#
# With neither --paseo nor --orphans, both run.

RAM_DO_PASEO=0
RAM_DO_ORPHANS=0
RAM_ORPHAN_AGE_MIN=60

# The processes the orphan reap will consider. Everything here holds a whole
# project index in RAM and has no live parent by the time it matches.
RAM_ORPHAN_MATCH='tsserver|typescript-language-server|vtsls|rust-analyzer|gopls|pyright|pylance|eslint_d|biome __server|jdtls'

ram_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --paseo) RAM_DO_PASEO=1; shift ;;
      --orphans) RAM_DO_ORPHANS=1; shift ;;
      --age) RAM_ORPHAN_AGE_MIN="${2:?--age needs a number of minutes, e.g. 120}"; shift 2 ;;
      -h | --help) ram_usage; exit 0 ;;
      *) die "ram: unknown argument: $1" ;;
    esac
  done
  if [ "${RAM_DO_PASEO}" -eq 0 ] && [ "${RAM_DO_ORPHANS}" -eq 0 ]; then
    RAM_DO_PASEO=1
    RAM_DO_ORPHANS=1
  fi
}

ram_usage() {
  sed -n '2,30p' "${DEVALOY_LIB}/ram.sh" | sed 's/^# \{0,1\}//'
}

# --- the scan -------------------------------------------------------------
#
# Tab-delimited: TYPE, PID, RSS_KB, STARTED, NOTE.
#
# STARTED IS THE REUSE GUARD, and it is the reason the PID half of the two-phase
# contract is safe at all. A path in a saved list either still exists or does
# not; a saved PID can belong to an entirely different process by the time you
# confirm, because Linux reuses PIDs. So the scan records the /proc start time
# alongside each PID and the apply re-reads it. A mismatch means the PID was
# recycled, and that process is skipped rather than killed.
ram_scan() {
  local out
  out="$(target_file ram)"
  : >"${out}"

  # --- the Paseo daemon ---------------------------------------------------
  #
  # This is the reclaim that pays for the command. The daemon is long-lived by
  # design and it accumulates: it holds a session per pane and outlives every
  # one of them. Restarting it is cheap because entrypoint.sh supervises it in a
  # `while true` loop and brings it back 10 seconds after it exits, with the
  # same config from ~/.paseo/config.json. So killing it IS the restart.
  #
  # WHAT YOU LOSE: every pane the daemon owns. An agent mid-turn in one of those
  # panes is killed with it.
  if [ "${RAM_DO_PASEO}" -eq 1 ]; then
    local roots pids pid rss
    roots="$(paseo_pids)"
    if [ -n "${roots}" ]; then
      pids="$(paseo_tree "${roots}")"
      for pid in ${pids}; do
        rss="$(awk '/^VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
        [ -n "${rss}" ] || continue
        printf 'paseo\t%s\t%s\t%s\t%s\n' \
          "${pid}" "${rss}" "$(proc_started "${pid}")" \
          "$(ps -o comm= -p "${pid}" 2>/dev/null || echo '?')" >>"${out}"
      done
    fi
  fi

  # --- orphaned language servers ------------------------------------------
  #
  # An editor or an agent session that dies without reaping its children leaves
  # tsserver, rust-analyzer and friends running forever, reparented to PID 1.
  # Each one holds its whole project index in RAM. They are the second biggest
  # reclaim on a box that has been up for weeks, and unlike a dev server nothing
  # is waiting on them.
  #
  # Two conditions, both required, because either alone is wrong:
  #
  #   ppid == 1     the parent is gone. A live server under a live editor has a
  #                 real parent and is not touched.
  #   idle >= age   it has burned no CPU recently. Guards the window between a
  #                 supervisor exiting and its child being cleaned up normally.
  if [ "${RAM_DO_ORPHANS}" -eq 1 ]; then
    local now started age pid ppid rss cputime comm
    now="$(date +%s)"
    while read -r pid ppid rss cputime comm; do
      [ "${ppid}" = "1" ] || continue
      started="$(proc_started "${pid}")"
      [ -n "${started}" ] || continue
      age=$((now - started))
      [ "${age}" -ge $((RAM_ORPHAN_AGE_MIN * 60)) ] || continue
      printf 'orphan\t%s\t%s\t%s\t%s (up %sm, cpu %ss)\n' \
        "${pid}" "${rss}" "${started}" "${comm}" "$((age / 60))" "${cputime}" >>"${out}"
    done < <(ps -eo pid=,ppid=,rss=,times=,comm= 2>/dev/null |
      grep -E "${RAM_ORPHAN_MATCH}" || true)
  fi

  # --- dev servers, recorded but never killed -----------------------------
  #
  # This block exists because the report is incomplete without it: when Paseo
  # and the orphans together account for 800 MB and the box is holding 5 GB,
  # this is where the rest went. The apply skips this type entirely.
  local pid rss args
  while read -r pid rss args; do
    printf 'devserver\t%s\t%s\t%s\t%s\n' \
      "${pid}" "${rss}" "$(proc_started "${pid}")" "${args}" >>"${out}"
  done < <(ps -eo pid=,rss=,args= --sort=-rss 2>/dev/null |
    grep -E 'next dev|vite|nuxt dev|webpack|turbo run|nodemon|jest --watch|vitest' |
    grep -v grep | head -8 | awk '{print $1, $2, $3, $4, $5}' || true)
}

ram_sum_kb() { # ram_sum_kb <type>
  awk -F'\t' -v t="$1" '$1 == t { s += $3 } END { print s + 0 }' "$(target_file ram)" 2>/dev/null
}

ram_count() { # ram_count <type>
  awk -F'\t' -v t="$1" '$1 == t { n++ } END { print n + 0 }' "$(target_file ram)" 2>/dev/null
}

# --- the view -------------------------------------------------------------

rows_ram() {
  emit "  ${BOLD}reclaimable${RESET}   ${DIM}scanned at $(now_stamp), orphan window ${RAM_ORPHAN_AGE_MIN}m${RESET}"
  emit_row '🧠' 'ram now' "$(status_ram_line)"
  emit_rule
  emit_row '🪟' 'paseo daemon tree' \
    "$(ram_count paseo) process(es), $(($(ram_sum_kb paseo) / 1024)) MiB — restart reclaims all of it"
  emit_row '👻' 'orphaned lsp servers' \
    "$(ram_count orphan) process(es), $(($(ram_sum_kb orphan) / 1024)) MiB"
  emit_row '🚧' 'dev servers' \
    "$(ram_count devserver) process(es), $(($(ram_sum_kb devserver) / 1024)) MiB — NOT killed"
  emit_rule
  if in_paseo_pane; then
    emit "  ${YELLOW}you are inside a Paseo pane${RESET}${DIM} — a restart kills this terminal${RESET}"
  fi
  emit "  ${DIM}  d shows every process before you apply${RESET}"
}

# --- the report -----------------------------------------------------------

ram_report_memory() { # ram_report_memory <when>
  local cur max swap swapmax
  cur="$(read_cg memory.current)"
  max="$(read_cg memory.max)"
  swap="$(read_cg memory.swap.current)"
  swapmax="$(read_cg memory.swap.max)"

  echo "devaloy ram: container memory $1"
  if [ -z "${cur}" ]; then
    echo "  (no cgroup v2 accounting readable — is this cgroup v1?)"
    return
  fi
  echo "  RAM  $(human "${cur}") of $(human "${max}")"
  echo "  swap $(human "${swap}") of $(human "${swapmax}")"
  if [ -n "${max}" ]; then
    echo "  used $((cur * 100 / max))% of the ceiling"
  else
    echo "  NOTE: no mem_limit is set. Nothing here protects the host — see"
    echo "        docs/wiki/vm-resource-limits.md."
  fi
}

ram_report() {
  local type pid rss started note

  ram_report_memory "before"

  echo
  echo "devaloy ram: top 10 processes by RSS"
  # The full command line is deliberately dropped: a Claude Code command line
  # runs to hundreds of columns and wraps the whole report.
  ps -eo rss=,pid=,ppid=,comm= --sort=-rss 2>/dev/null | head -10 |
    while read -r rss pid ppid comm; do
      printf '  %8s MiB  pid %-7s ppid %-7s %s\n' \
        "$((rss / 1024))" "${pid}" "${ppid}" "${comm}"
    done

  if [ "${RAM_DO_PASEO}" -eq 1 ]; then
    echo
    if [ "$(ram_count paseo)" -eq 0 ]; then
      echo "devaloy ram: no Paseo daemon running (WITH_PASEO off, or it is down)"
    else
      printf 'devaloy ram: the Paseo daemon and its children hold %s MiB across %s process(es)\n' \
        "$(($(ram_sum_kb paseo) / 1024))" "$(ram_count paseo)"
      echo "devaloy ram: the largest of them"
      # int(), because awk division is floating point and "1989.74 MiB" of RSS
      # is a precision the kernel never offered.
      awk -F'\t' '$1 == "paseo" { printf "  %6d MiB  pid %-7s %s\n", int($3/1024), $2, $5 }' \
        "$(target_file ram)" | sort -rn | head -5
      if in_paseo_pane; then
        echo "devaloy ram: WARNING — this session is a Paseo pane. A restart kills it."
      fi
    fi
  fi

  if [ "${RAM_DO_ORPHANS}" -eq 1 ]; then
    echo
    echo "devaloy ram: orphaned language servers (ppid 1, idle >= ${RAM_ORPHAN_AGE_MIN}m)"
    if [ "$(ram_count orphan)" -eq 0 ]; then
      echo "  none"
    else
      while IFS=$'\t' read -r type pid rss started note; do
        [ "${type}" = "orphan" ] || continue
        printf '  %6s MiB  pid %-7s %s\n' "$((rss / 1024))" "${pid}" "${note}"
      done <"$(target_file ram)"
    fi
  fi

  echo
  echo "devaloy ram: dev servers and builds (NOT killed — stop these yourself)"
  if [ "$(ram_count devserver)" -eq 0 ]; then
    echo "  none"
  else
    while IFS=$'\t' read -r type pid rss started note; do
      [ "${type}" = "devserver" ] || continue
      printf '  %6s MiB  pid %-7s %s\n' "$((rss / 1024))" "${pid}" "${note}"
    done <"$(target_file ram)"
  fi
}

# --- the apply ------------------------------------------------------------

ram_apply_targets() {
  local type pid rss started note now_started killed=0 killed_kb=0 skipped=0

  # --- the orphan reap ----------------------------------------------------
  if [ "${RAM_DO_ORPHANS}" -eq 1 ] && [ "$(ram_count orphan)" -gt 0 ]; then
    while IFS=$'\t' read -r type pid rss started note; do
      [ "${type}" = "orphan" ] || continue
      now_started="$(proc_started "${pid}")"
      if [ -z "${now_started}" ]; then
        # Already gone between the scan and here. Nothing to do and nothing
        # wrong; it is the outcome we wanted.
        continue
      fi
      if [ "${now_started}" != "${started}" ]; then
        # THE PID WAS REUSED. Killing it now would hit a process that started
        # after you read the report, which is the one thing the two-phase
        # contract exists to prevent.
        skipped=$((skipped + 1))
        printf 'devaloy ram: pid %s was recycled since the scan — skipped\n' "${pid}"
        continue
      fi
      # TERM only. A language server that ignores it is one that is still doing
      # something, and escalating to -9 here would corrupt an index it may share
      # with a live editor.
      act kill -TERM "${pid}" 2>/dev/null || true
      killed=$((killed + 1))
      killed_kb=$((killed_kb + rss))
    done <"$(target_file ram)"

    if [ "${APPLY}" -eq 1 ]; then
      printf 'devaloy ram: sent TERM to %s process(es), %s MiB\n' \
        "${killed}" "$((killed_kb / 1024))"
    else
      printf 'devaloy ram: would TERM %s process(es), %s MiB\n' \
        "${killed}" "$((killed_kb / 1024))"
    fi
    [ "${skipped}" -gt 0 ] && printf 'devaloy ram: %s skipped as recycled\n' "${skipped}"
  fi

  # --- the Paseo restart --------------------------------------------------
  #
  # Not a PID kill from the saved list, and deliberately so. pkill by pattern is
  # used because it also works when the daemon is wedged badly enough that a
  # signal to one recorded PID does not bring the tree down, which is the state
  # you are usually in when you came looking for this. The saved list is what
  # sized the reclaim; the pattern is what performs it.
  if [ "${RAM_DO_PASEO}" -eq 1 ] && [ "$(ram_count paseo)" -gt 0 ]; then
    echo
    if [ "${APPLY}" -eq 0 ]; then
      echo "devaloy ram: would restart the Paseo daemon (--apply to do it)"
    else
      echo "devaloy ram: stopping the daemon — every open pane dies with it"
      # SIGTERM, not SIGKILL. Paseo's own supervisor flushes session state and
      # releases the PID lock under ~/.paseo on a clean signal; a -9 leaves the
      # lock behind and the restart then fights it.
      #
      # -u restricts the kill to processes this user owns. Without it the
      # pattern also matches the root-owned `su -l -s /bin/sh` that
      # entrypoint.sh uses to drop into the dev user, and pkill prints
      # "Operation not permitted" for a process it never needed to signal.
      #
      # -xf, matching paseo_pids in common.sh. A substring pattern here matches
      # devaloy's own command line, so the reclaim would TERM itself.
      pkill -u "$(id -u)" -xf "${PASEO_DAEMON_TITLE}" || true

      # The supervisor loop in entrypoint.sh sleeps 10s before restarting, so
      # this waits past that and then confirms. Without the confirmation you
      # cannot tell a successful restart from a daemon that is now permanently
      # down.
      local waited=0
      while [ "${waited}" -lt 40 ]; do
        sleep 2
        waited=$((waited + 2))
        if [ -n "$(paseo_pids)" ]; then
          echo "devaloy ram: daemon back up after ${waited}s"
          break
        fi
      done
      if [ -z "$(paseo_pids)" ]; then
        echo "devaloy ram: WARNING — the daemon has not come back after ${waited}s." >&2
        echo "devaloy ram: check 'docker logs' for this container; the supervisor" >&2
        echo "devaloy ram: retries every 10s and logs each failure." >&2
      fi
    fi
  fi

  if [ "${APPLY}" -eq 1 ]; then
    # The kernel does not return freed pages to memory.current instantly, and a
    # TERMed process takes a moment to actually leave. Without this pause the
    # "after" reading is the "before" reading and it looks like nothing happened.
    sleep 3
    echo
    ram_report_memory "after"
  fi
}

ram_apply() {
  local lines=()
  lines+=("devaloy ram will TERM $(ram_count orphan) orphaned language server(s), $(($(ram_sum_kb orphan) / 1024)) MiB.")
  if [ "$(ram_count paseo)" -gt 0 ]; then
    lines+=("It will also restart the Paseo daemon, killing every open pane and every")
    lines+=("agent mid-turn in one, to reclaim $(($(ram_sum_kb paseo) / 1024)) MiB.")
  fi
  if in_paseo_pane; then
    lines+=("")
    lines+=("THIS SESSION IS A PASEO PANE. The restart kills the terminal you are")
    lines+=("reading this in. You will not see the 'daemon back up' confirmation.")
  fi
  lines+=("Dev servers are never killed.")

  if ! confirm "${lines[@]}"; then
    printf '\n  cancelled\n'
    sleep 1
    return 0
  fi
  APPLY=1
  run_raw ram_apply_targets
  APPLY=0
}

do_ram() {
  ram_args "$@"
  ram_scan
  ram_report
  ram_apply_targets
  if [ "${APPLY}" -eq 0 ]; then
    echo
    echo "devaloy ram: report only. Nothing was killed. Pass --apply to act."
  fi
}
