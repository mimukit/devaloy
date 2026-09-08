#!/usr/bin/env bash
# devaloy: reclaim disk from the home volume, by hand.
#
# devaloy prune covers the nested Docker daemon and nothing else. This covers
# the rest of /home/dev, which on a box that has been cloning repos and running
# agents for a month is the larger share: node_modules trees for projects you
# stopped working on, worktrees whose branch merged weeks ago, and package
# manager caches that never shrink on their own.
#
# It matters more when two devaloy boxes share one VPS. Each one has its own
# home volume on the same disk, so the two compete for the same free space, and
# a swap file sized for aggressive swapping is competing with them.
#
# DRY RUN BY DEFAULT. Nothing is deleted until you pass --apply.
#
# TWO PHASES, one delete path. disk_scan walks the volume and writes every
# target to a file. disk_report prints that file. disk_apply deletes from that
# same file and nothing else. So the list you read is the list that runs — a
# second walk between the report and the confirm could turn up a tree you never
# saw listed, which is exactly the case the dry run exists to prevent. The CLI
# runs the same three functions in the same order as the TUI, so there is no
# second code path to forget to guard.
#
# Scope is /home/dev only. -xdev keeps every find on the home volume, so a
# mounted project stack volume or /var/lib/docker is never walked.
#
# Usage: devaloy disk [--apply] [--age <days>] [--docker] [--caches]
#   --apply        actually delete. Without it, this only lists.
#   --age <days>   a node_modules must be untouched this long to qualify.
#                  Default 30.
#   --docker       also hand off to the docker reclaim at the end
#   --caches       also clear the pnpm/npm/mise download caches

DISK_AGE_DAYS=30
DISK_DO_DOCKER=0
DISK_DO_CACHES=0
DISK_ROOT="${HOME:-/home/dev}"

disk_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --age) DISK_AGE_DAYS="${2:?--age needs a number of days, e.g. 14}"; shift 2 ;;
      --docker) DISK_DO_DOCKER=1; shift ;;
      --caches) DISK_DO_CACHES=1; shift ;;
      -h | --help) disk_usage; exit 0 ;;
      *) die "disk: unknown argument: $1" ;;
    esac
  done
}

disk_usage() {
  sed -n '2,32p' "${DEVALOY_LIB}/disk.sh" | sed 's/^# \{0,1\}//'
}

# --- the scan -------------------------------------------------------------
#
# Writes one tab-delimited line per target: TYPE, PATH, SIZE_KB, NOTE.
# TYPE decides what the apply does with it, so a new kind of reclaim is a new
# type here and a new case in disk_apply, with the report needing no change.
disk_scan() {
  local out
  out="$(target_file disk)"
  : >"${out}"

  # --- node_modules -------------------------------------------------------
  #
  # -prune is load-bearing: without it find descends INTO each node_modules and
  # reports every nested one, so a single project yields hundreds of hits and
  # the sizes double-count.
  #
  # The age test is on the node_modules directory's own mtime, which a package
  # manager touches on every install. That makes it a proxy for "when did anyone
  # last work here", not a measurement of it. The last commit date is recorded
  # beside it so you can overrule the proxy by eye before applying.
  #
  # THE EXCLUSIONS ARE NOT OPTIONAL. pnpm's content-addressable store keeps a
  # `node_modules` directory inside every package it has ever linked, and so
  # does `.npm/_npx`. Without the first -path group this walk matched 333 of
  # them on this box and offered to delete the store itself, which would break
  # every project's install at once rather than one project's. Anything you add
  # to this list must be pruned BEFORE the -name test, or find still descends
  # into it.
  local nm size_kb project last_commit
  while IFS= read -r nm; do
    [ -n "${nm}" ] || continue
    size_kb="$(du -sk "${nm}" 2>/dev/null | cut -f1)"
    [ -n "${size_kb}" ] || continue
    project="$(dirname "${nm}")"
    last_commit="$(git -C "${project}" log -1 --format=%cr 2>/dev/null || true)"
    [ -n "${last_commit}" ] || last_commit="not a git repo"
    printf 'nm\t%s\t%s\tlast commit: %s\n' "${nm}" "${size_kb}" "${last_commit}" >>"${out}"
  done < <(find "${DISK_ROOT}" -xdev \
    \( -path "${DISK_ROOT}/.local/share/pnpm" \
    -o -path "${DISK_ROOT}/.npm" \
    -o -path "${DISK_ROOT}/.cache" \
    -o -path "${DISK_ROOT}/.bun" \
    -o -path "${DISK_ROOT}/.local/share/mise" \
    -o -name '.pnpm' \
    -o -name '.git' \) -prune -o \
    -type d -name node_modules -prune -mtime "+${DISK_AGE_DAYS}" \
    -print 2>/dev/null | sort)

  # --- git worktrees ------------------------------------------------------
  #
  # `git worktree prune` only removes ADMIN records whose working directory is
  # already gone — it never deletes a directory that still exists, so it is safe
  # to run everywhere and it reclaims almost nothing on its own. What it does is
  # make `git worktree list` honest again.
  #
  # The real disk is in worktrees that still exist and whose branch has merged.
  # Those are NOT deleted here, on purpose: a worktree can hold uncommitted
  # work, and this cannot tell that from a stale checkout. They are listed, and
  # the gitkit skill's sweep is the thing that removes them with the branch
  # state checked properly.
  local gitdir repo prunable extra
  while IFS= read -r gitdir; do
    repo="$(dirname "${gitdir}")"
    # --porcelain marks an unusable record with a `prunable` line. Anything else
    # is a live worktree.
    prunable="$(git -C "${repo}" worktree list --porcelain 2>/dev/null |
      grep -c '^prunable' || true)"
    extra="$(git -C "${repo}" worktree list 2>/dev/null | tail -n +2 | wc -l || true)"
    [ "${prunable:-0}" -eq 0 ] && [ "${extra:-0}" -eq 0 ] && continue
    printf 'wt\t%s\t0\t%s linked worktree(s), %s prunable\n' \
      "${repo}" "${extra}" "${prunable}" >>"${out}"
  done < <(find "${DISK_ROOT}" -xdev -maxdepth 4 -type d -name .git 2>/dev/null | sort)

  # --- stale mise tool versions -------------------------------------------
  #
  # THE BIGGEST RECLAIM ON A BOX THAT HAS BEEN UP FOR WEEKS, and the least
  # obvious. Every tool in bootstrap-toolchain.sh that tracks `latest` — claude,
  # codex, pnpm, gh — installs a NEW versioned directory on each update and
  # keeps every older one. Nothing reaps them. Measured on the reference box: 18
  # versions of claude at 4.8 GB and 12 of codex at 3.8 GB, with exactly one of
  # each in use.
  #
  # `mise prune` is the right tool rather than an rm loop. It reads
  # ~/.local/state/mise/tracked-configs and tracked-stubs, keeps whatever is
  # still the latest version named in any of them, and deletes the rest along
  # with the matching ~/.cache/mise entries. The version you are running is
  # never a candidate, so this cannot leave the box without a toolchain.
  #
  # It is therefore the one target that is NOT a path: the row records the tool
  # so the report can show the size, and the apply runs `mise prune` once.
  if command -v mise >/dev/null 2>&1; then
    local mise_installs path versions
    mise_installs="${DISK_ROOT}/.local/share/mise/installs"
    if [ -d "${mise_installs}" ]; then
      while read -r size_kb path; do
        [ -n "${path}" ] || continue
        versions="$(find "${path}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
        # The count is every installed version of that tool, including the
        # active one, so "18 versions" reads as "17 of these are dead weight".
        printf 'mise\t%s\t%s\t%s version(s) installed\n' \
          "${path}" "${size_kb}" "${versions}" >>"${out}"
      done < <(du -sk "${mise_installs}"/* 2>/dev/null | sort -rn | head -6)
    fi
  fi

  # --- Paseo daemon logs --------------------------------------------------
  #
  # The daemon writes a new timestamped log per start and rotates none of them.
  # Small next to the mise reclaim, but unbounded: on a box where the ram
  # reclaim restarts the daemon nightly, this grows a file per night forever.
  #
  # The live daemon.log is not matched by the glob — it has no timestamp prefix
  # — so the daemon never loses the file it is writing to.
  if [ -d "${DISK_ROOT}/.paseo" ]; then
    local f
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      printf 'log\t%s\t%s\tpaseo daemon log\n' \
        "${f}" "$(du -sk "${f}" 2>/dev/null | cut -f1)" >>"${out}"
    done < <(find "${DISK_ROOT}/.paseo" -maxdepth 1 -type f -name '*-daemon.log' \
      -mtime "+${DISK_AGE_DAYS}" 2>/dev/null | sort)
  fi

  # --- caches -------------------------------------------------------------
  #
  # Opt-in because every one of these costs a re-download on the next install,
  # and on a box behind Tailscale that is minutes rather than seconds. Worth it
  # when the disk is genuinely full, wasteful otherwise.
  if [ "${DISK_DO_CACHES}" -eq 1 ]; then
    local c
    for c in "${DISK_ROOT}/.local/share/pnpm/store" "${DISK_ROOT}/.npm" \
      "${DISK_ROOT}/.cache/mise" "${DISK_ROOT}/.cache/turbo"; do
      [ -d "${c}" ] || continue
      printf 'cache\t%s\t%s\tpackage manager cache\n' \
        "${c}" "$(du -sk "${c}" 2>/dev/null | cut -f1)" >>"${out}"
    done
  fi
}

# --- reading the scan back ------------------------------------------------

disk_sum_kb() { # disk_sum_kb <type>
  awk -F'\t' -v t="$1" '$1 == t { s += $3 } END { print s + 0 }' "$(target_file disk)" 2>/dev/null
}

disk_count() { # disk_count <type>
  awk -F'\t' -v t="$1" '$1 == t { n++ } END { print n + 0 }' "$(target_file disk)" 2>/dev/null
}

rows_disk() {
  emit_head 'reclaimable' "scanned at $(now_stamp), age window ${DISK_AGE_DAYS}d"
  emit_row '📦' 'node_modules' \
    "$(disk_count nm) tree(s), $(($(disk_sum_kb nm) / 1024)) MiB"
  emit_row '🔧' 'stale mise versions' \
    "$(disk_count mise) tool(s), $(($(disk_sum_kb mise) / 1024)) MiB installed"
  emit_row '📄' 'paseo logs' \
    "$(disk_count log) file(s), $(($(disk_sum_kb log) / 1024)) MiB"
  if [ "${DISK_DO_CACHES}" -eq 1 ]; then
    emit_row '📚' 'caches' \
      "$(disk_count cache) dir(s), $(($(disk_sum_kb cache) / 1024)) MiB"
  else
    emit_row '📚' 'caches' "not scanned — devaloy disk --caches includes them"
  fi
  emit_row '🌿' 'git worktrees' \
    "$(disk_count wt) repo(s) with linked worktrees — listed, never deleted"
  emit_rule
  emit_row '💾' 'disk now' "$(status_disk_line)"
}

# --- the report -----------------------------------------------------------

disk_report() {
  local type path size_kb note

  echo "devaloy disk: disk before"
  df -h "${DISK_ROOT}" | tail -1
  echo

  echo "devaloy disk: node_modules untouched for ${DISK_AGE_DAYS}+ days"
  if [ "$(disk_count nm)" -eq 0 ]; then
    echo "  none"
  else
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "nm" ] || continue
      printf '  %6s MiB  %s\n' "$((size_kb / 1024))" "${path#"${DISK_ROOT}"/}"
      printf '               %s\n' "${note}"
    done <"$(target_file disk)"
    printf 'devaloy disk: %s tree(s), %s MiB\n' \
      "$(disk_count nm)" "$(($(disk_sum_kb nm) / 1024))"
  fi

  echo
  echo "devaloy disk: git worktrees"
  if [ "$(disk_count wt)" -eq 0 ]; then
    echo "  no repos with linked or prunable worktrees"
  else
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "wt" ] || continue
      echo "  ${path#"${DISK_ROOT}"/}: ${note}"
      git -C "${path}" worktree list 2>/dev/null | tail -n +2 | sed 's/^/      /'
    done <"$(target_file disk)"
  fi
  echo "  (a linked worktree may hold uncommitted work — use gitkit's sweep to"
  echo "   remove merged ones, not this command)"

  echo
  echo "devaloy disk: stale mise tool versions"
  if [ "$(disk_count mise)" -eq 0 ]; then
    command -v mise >/dev/null 2>&1 || echo "  mise not on PATH"
    [ "$(disk_count mise)" -eq 0 ] && echo "  nothing installed under mise"
  else
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "mise" ] || continue
      printf '  %6s MiB  %-20s %s\n' \
        "$((size_kb / 1024))" "$(basename "${path}")" "${note}"
    done <"$(target_file disk)"
    echo "  full list with 'mise prune --dry-run'"
  fi

  if [ "$(disk_count log)" -gt 0 ]; then
    echo
    echo "devaloy disk: Paseo daemon logs older than ${DISK_AGE_DAYS} days"
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "log" ] || continue
      printf '  %6s KiB  %s\n' "${size_kb}" "$(basename "${path}")"
    done <"$(target_file disk)"
  fi

  if [ "${DISK_DO_CACHES}" -eq 1 ]; then
    echo
    echo "devaloy disk: package manager caches"
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "cache" ] || continue
      printf '  %6s MiB  %s\n' "$((size_kb / 1024))" "${path#"${DISK_ROOT}"/}"
    done <"$(target_file disk)"
  fi
}

# --- the apply ------------------------------------------------------------
#
# Consumes the file the scan wrote, and touches nothing that is not in it. The
# exception is the `mise` type, whose row is a size report rather than a path:
# `mise prune` decides which versions to drop from its own tracked-configs, and
# an rm loop over those directories would be the thing that leaves the box
# without a toolchain.
disk_apply_targets() {
  local type path size_kb note removed_kb=0 removed=0 did_mise=0

  while IFS=$'\t' read -r type path size_kb note; do
    case "${type}" in
      nm | log | cache)
        # The path may have gone since the scan. That is fine and expected: the
        # contract is that nothing OUTSIDE the list is touched, not that
        # everything in it still exists.
        [ -e "${path}" ] || continue
        act rm -rf "${path}"
        removed=$((removed + 1))
        removed_kb=$((removed_kb + size_kb))
        ;;
      wt)
        act git -C "${path}" worktree prune
        ;;
      mise)
        [ "${did_mise}" -eq 1 ] && continue
        did_mise=1
        if [ "${APPLY}" -eq 1 ]; then
          echo "devaloy disk: pruning unused mise versions"
          mise prune || true
        else
          echo "devaloy disk: would run: mise prune"
        fi
        ;;
    esac
  done <"$(target_file disk)"

  if [ "${DISK_DO_CACHES}" -eq 1 ] && [ "${APPLY}" -eq 1 ]; then
    # `pnpm store prune` rather than rm -rf: it drops packages no lockfile on
    # the box references and keeps the rest, so the projects you still work on
    # reinstall from the store instead of the network.
    command -v pnpm >/dev/null 2>&1 && pnpm store prune || true
    command -v npm >/dev/null 2>&1 && npm cache clean --force >/dev/null 2>&1 || true
  fi

  if [ "${APPLY}" -eq 1 ]; then
    printf 'devaloy disk: removed %s path(s), %s MiB\n' "${removed}" "$((removed_kb / 1024))"
  else
    printf 'devaloy disk: would remove %s path(s), %s MiB\n' "${removed}" "$((removed_kb / 1024))"
  fi

  # Delegated rather than reimplemented. The docker reclaim already handles the
  # no-daemon case, the age window and the --all blade, and duplicating its
  # filters here is how the two drift.
  if [ "${DISK_DO_DOCKER}" -eq 1 ]; then
    echo
    if [ "${APPLY}" -eq 1 ]; then
      echo "devaloy disk: handing off to the docker reclaim"
      do_prune --age "$((DISK_AGE_DAYS * 24))h" || true
    else
      echo "devaloy disk: would run: devaloy prune --age $((DISK_AGE_DAYS * 24))h"
      docker system df 2>/dev/null || echo "  (no Docker daemon on this box)"
    fi
  fi

  echo
  echo "devaloy disk: disk after"
  df -h "${DISK_ROOT}" | tail -1
}

# The TUI's `a`. The report is already on screen, so this confirms against the
# counts from the scan and then runs the same apply the CLI runs.
disk_apply() {
  local mib
  mib="$(((  $(disk_sum_kb nm) + $(disk_sum_kb log) + $(disk_sum_kb cache) ) / 1024))"
  if ! confirm \
    "devaloy disk will delete $(disk_count nm) node_modules tree(s), $(disk_count log) Paseo log(s)," \
    "reclaiming about ${mib} MiB, and run mise prune." \
    "It deletes only what the report listed. Worktrees are never deleted."; then
    printf '\n  cancelled\n'
    sleep 1
    return 0
  fi
  # Set and reset explicitly rather than `APPLY=1 disk_apply_targets`: a prefix
  # assignment on a function call leaks into the shell in POSIX mode, and this
  # is the one variable that must never stay set by accident.
  APPLY=1
  run_raw disk_apply_targets
  APPLY=0
}

do_disk() {
  disk_args "$@"
  disk_scan
  disk_report
  disk_apply_targets
  if [ "${APPLY}" -eq 0 ]; then
    echo
    echo "devaloy disk: dry run. Nothing was deleted. Pass --apply to act."
  fi
}
