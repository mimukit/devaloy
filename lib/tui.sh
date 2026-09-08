#!/usr/bin/env bash
# devaloy: the picker.
#
# Ported from the `ip` script in mimukit/dotfiles, and the two structural
# choices there are load-bearing here for the same reasons.
#
# ONE FZF PROCESS PER VIEW. A view change exits fzf and starts it again, driven
# by the loop in cmd_pick. The obvious alternative, one long-lived fzf whose
# list a `reload` binding swaps, was built first for `ip` and looked wrong:
# --height='~85%' measures the list once at startup and never grows, so every
# view after the root was clipped to the root's height, and fzf has no
# change-height action to fix it from a binding. Restarting re-measures, so each
# view is exactly as tall as its own content. --expect reports which key ended
# the run and the loop routes on it.
#
# KEYS ARE SINGLE LETTERS, vim style, which needs --no-input. Without it fzf
# treats every printable key as search input and `j` types a `j`.
#
# An action never renders into this list. It exits fzf and streams on the raw
# terminal, exactly as the five scripts do today, because a five-minute
# `bootstrap-toolchain.sh --force` is worth watching and a `df` table does not
# survive being cut into tab-delimited fields.

# fzf gained --no-input in 0.54 and --footer/transform-footer in 0.65. Below
# that the TUI half-renders: the footer vanishes and every key becomes search
# input, which looks like a broken program rather than an old one.
FZF_FLOOR_MAJOR=0
FZF_FLOOR_MINOR=65

fzf_version_ok() {
  local v major minor
  v="$(fzf --version 2>/dev/null | awk '{print $1}')"
  [ -n "${v}" ] || return 1
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  [ "${major:-0}" -gt "${FZF_FLOOR_MAJOR}" ] && return 0
  [ "${major:-0}" -eq "${FZF_FLOOR_MAJOR}" ] && [ "${minor:-0}" -ge "${FZF_FLOOR_MINOR}" ]
}

# --- row helpers ----------------------------------------------------------
#
# Four tab-delimited fields: what you see, the value a detail view needs, the
# view `enter` descends into, and the view `d` opens. fzf shows field 1 only.
emit() { # emit <label> [value] [target view] [detail view]
  printf '%s\t%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" "${4:-}"
}

emit_row() { # emit_row <icon> <label> <value>
  emit "$(printf '  %s  %-22s %s' "$1" "$2" "$3")"
}

emit_branch() { # emit_branch <icon> <label> <blurb> <view>
  emit "$(printf '  %s  %-22s %s%s%s' "$1" "$2" "${DIM}" "$3" "${RESET}")" '' "$4"
}

emit_rule() {
  emit "${DIM}  ────────────────────────────────────────────────${RESET}"
}

# --- running an action on the raw terminal --------------------------------
#
# fzf has already exited by the time this runs — cmd_pick got here through
# --expect — so there is no terminal state to save. The pause at the end is the
# whole reason this is a function: without it the picker redraws over the output
# before you have read it.
run_raw() { # run_raw <command...>
  printf '\n'
  "$@" || true
  printf '\n%s  press any key to return to devaloy%s' "${DIM}" "${RESET}"
  read -r -n 1 -s _ </dev/tty || true
  printf '\n'
}

confirm() { # confirm <prompt line...>
  # Deliberately a plain read on /dev/tty, not an fzf prompt. The confirm is the
  # last thing between a report and a delete, so it must not depend on the same
  # process that just exited.
  local line reply
  printf '\n'
  for line in "$@"; do
    printf '  %s\n' "${line}"
  done
  printf '\n  %stype yes to proceed:%s ' "${BOLD}" "${RESET}"
  read -r reply </dev/tty || reply=''
  [ "${reply}" = "yes" ]
}

# --- the view table -------------------------------------------------------

cmd_view() { # cmd_view <view> [arg]
  case "$1" in
    status) rows_status ;;
    disk) rows_disk ;;
    ram) rows_ram ;;
    prune) rows_prune ;;
    doctor) rows_doctor ;;
    tools) rows_tools ;;
    *) die "unknown view: $1" ;;
  esac
}

label_of() {
  case "$1" in
    status) printf ' devaloy ' ;;
    disk) printf ' disk reclaim ' ;;
    ram) printf ' ram reclaim ' ;;
    prune) printf ' docker reclaim ' ;;
    doctor) printf ' doctor ' ;;
    tools) printf ' toolchain ' ;;
  esac
}

footer_of() {
  case "$1" in
    status) printf '  j/k move · l open · r refresh · q quit' ;;
    disk | ram | prune) printf '  a apply · d full report · r rescan · h back' ;;
    doctor) printf '  r recheck · h back · q quit' ;;
    tools) printf '  a run · h back · q quit' ;;
    *) printf '  h back · q quit' ;;
  esac
}

parent_of() {
  case "$1" in
    status) printf '' ;;
    *) printf 'status' ;;
  esac
}

# Which views own an `a` key, and what it runs. Kept as one table rather than a
# branch inside cmd_pick, so adding a verb is one line in one place.
apply_of() { # apply_of <view>
  case "$1" in
    disk) printf 'disk_apply' ;;
    ram) printf 'ram_apply' ;;
    prune) printf 'prune_apply' ;;
    tools) printf 'tools_apply' ;;
    *) printf '' ;;
  esac
}

detail_of() { # detail_of <view>
  case "$1" in
    disk) printf 'disk_report' ;;
    ram) printf 'ram_report' ;;
    prune) printf 'prune_report' ;;
    doctor) printf 'doctor_report' ;;
    *) printf '' ;;
  esac
}

# A view that has to walk the filesystem or the process table before it can draw
# a summary. Entering it runs the scan; `r` runs it again.
scan_of() { # scan_of <view>
  case "$1" in
    disk) printf 'disk_scan' ;;
    ram) printf 'ram_scan' ;;
    prune) printf 'prune_scan' ;;
    *) printf '' ;;
  esac
}

# --- the loop -------------------------------------------------------------

cmd_pick() {
  require fzf

  fzf_version_ok || die "the TUI needs fzf 0.${FZF_FLOOR_MINOR} or later (this box has $(fzf --version 2>/dev/null | awk '{print $1}' || echo none)). Run devaloy-update, then try again. Every verb still works from the command line: devaloy --help"

  local view=status pos=1 back_pos=1 note='' scan apply detail
  local out key line value target idx rc up

  while true; do
    scan="$(scan_of "${view}")"
    if [ -n "${scan}" ] && [ ! -s "$(target_file "${view}")" ]; then
      # Drawn on the raw terminal, because a find over the whole home volume
      # takes seconds and a picker that opens on an empty box reads as broken.
      printf '  %sscanning…%s\n' "${DIM}" "${RESET}"
      "${scan}"
    fi

    rc=0
    out="$(cmd_view "${view}" |
      awk -F'\t' -v OFS='\t' '{ print $1, $2, $3, $4, NR }' |
      fzf \
        --delimiter=$'\t' \
        --with-nth=1 \
        --ansi \
        --no-sort \
        --no-multi \
        --no-input \
        --cycle \
        --info=hidden \
        --layout=reverse \
        --height='~85%' \
        --min-height=8 \
        --border=rounded \
        --border-label="$(label_of "${view}")" \
        --border-label-pos=3 \
        --footer="${note:-$(footer_of "${view}")}" \
        --pointer='▸' \
        --expect='enter,l,a,d,h,esc,r,q' \
        --bind="start:pos(${pos})" \
        --bind='j:down' \
        --bind='k:up' \
        --bind='g:first' \
        --bind='G:last' \
        --bind='ctrl-d:half-page-down' \
        --bind='ctrl-u:half-page-up' \
        --bind='ctrl-c:abort')" || rc=$?

    # 130 is ctrl-c, 1 is an empty list. Both mean stop.
    [ "${rc}" -eq 0 ] && [ -n "${out}" ] || return 0

    note=''
    key="${out%%$'\n'*}"
    line="${out#*$'\n'}"
    value="$(printf '%s' "${line}" | cut -f2)"
    target="$(printf '%s' "${line}" | cut -f3)"
    idx="$(printf '%s' "${line}" | cut -f5)"
    [ -n "${idx}" ] || idx=1

    apply="$(apply_of "${view}")"
    detail="$(detail_of "${view}")"

    case "${key}" in
      q) return 0 ;;

      h | esc)
        up="$(parent_of "${view}")"
        [ -n "${up}" ] || return 0
        view="${up}"
        pos="${back_pos}"
        back_pos=1
        ;;

      enter | l)
        if [ -n "${target}" ]; then
          back_pos="${idx}"
          view="${target}"
          pos=1
        else
          note='  nothing to open on that row'
          pos="${idx}"
        fi
        ;;

      a)
        pos="${idx}"
        if [ -n "${apply}" ]; then
          # The row's value field goes with it. Most applies ignore it; the
          # toolchain view uses it to say which of its two commands to run.
          "${apply}" "${value}"
          # The numbers moved, so every cached scan is now a lie. Drop them and
          # let the next draw re-read. This is the "refresh on return from an
          # action" half of the status contract.
          rm -f "$(rundir)"/*.targets 2>/dev/null || true
        else
          note='  nothing to apply in this view'
        fi
        ;;

      d)
        pos="${idx}"
        if [ -n "${detail}" ]; then
          run_raw "${detail}"
        else
          note='  nothing more to show here'
        fi
        ;;

      r)
        pos="${idx}"
        rm -f "$(target_file "${view}")" 2>/dev/null || true
        note="  refreshed at $(now_stamp)"
        ;;

      *) return 0 ;;
    esac
  done
}
