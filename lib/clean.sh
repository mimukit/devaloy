#!/usr/bin/env bash
# devaloy: the routine reclaim, the disk half and the Docker half in one pass.
#
# devaloy disk and devaloy prune each cover half of the box, and a routine run
# needs both with the same choices every time: caches on, build cache older
# than a day, dangling images only. This runs the two scans, prints one report,
# and applies both from the rows it listed. It holds no filter of its own; every
# rule lives in lib/disk.sh or lib/prune.sh.
#
# DRY RUN BY DEFAULT. Nothing is deleted until you pass --apply. The contract is
# the one disk and prune keep: scan to a target file, report from that file,
# apply from that file only.
#
# Usage: devaloy clean [--apply] [--all] [--age <days>] [--logs <days>]
#                      [--no-caches] [--json] [--save <file>] [--from <file>]
#   --apply          actually delete. Without it, this only reports.
#   --all            also remove images no container is running, not only
#                    dangling ones
#   --age <days>     a node_modules must be untouched this long. Default 30.
#   --logs <days>    also remove agent logs older than <days> (7 or more)
#   --no-caches      leave the download caches, the pnpm store and the
#                    Playwright revisions alone (on by default here)
#   --json           print one JSON object (below) on stdout and nothing else;
#                    with --apply, the apply output goes to stderr
#   --save <file>    write the scanned rows to <file>
#   --from <file>    use the rows in <file> instead of a new scan. A file older
#                    than 60 minutes is refused. Each row is checked again: a
#                    known type, a path under the home volume, and not on the
#                    never-delete list. A failing row is dropped with a message.
#                    Without --apply it only reports.
#
# Fixed here: the disk half runs with --caches and never with --docker, and the
# Docker half prunes build cache older than 24h (devaloy prune keeps 168h).
# Build cache, images and npm cache clean are not rows a file can list, so
# `--apply --from` still runs them. mise prune runs for the tools the mise rows
# name, and pnpm store prune when the file has a pstore row. Only the paths and
# the volumes come from the file.
#
# THE SAVED FILE is TSV with no header, one row per line: TYPE, PATH, SIZE_KB,
# NOTE, and on nm and wtnm rows FREE_KB. Disk types: nm wt mise log cache
# pstore pw pwkeep wtnm alog. Docker type: dvol, whose PATH is a volume name. A
# mise row's PATH is the install directory and its NOTE is tool@version.
#
# TWO SIZES. SIZE_KB is what `du -sk` reports. FREE_KB is the least the delete
# frees: pnpm hard-links node_modules files from its store, and a file is freed
# only when no other path links it. See disk_measure in lib/disk.sh.
#
# THE JSON SCHEMA. A change may add a field, never rename one, because the
# devaloy-clean skill reads it.
#   {
#     "disk":   [ {type, path, size_kb, note, min_free_kb} ],  every disk row
#     "docker": { "available": bool,
#                 "summary": [ {type, count, size, reclaimable} ],
#                 "volumes": [ {type, path, size_kb, note, min_free_kb} ] },
#     "totals": { disk_paths, disk_kb, volumes, volume_kb, total_kb, total_mib,
#                 disk_min_free_kb, total_min_free_kb, total_min_free_mib }
#   }
# totals count only rows the apply deletes (nm wtnm log alog cache pw, and dvol).
# total_mib is the most the apply frees and total_min_free_mib the least.
# min_free_kb is FREE_KB where the row has one, else size_kb. Build cache and
# images are in docker.summary, not in totals. With --from the summary is
# empty, because nothing is scanned.

CLEAN_DO_CACHES=1
CLEAN_BUILDER_AGE='24h'
CLEAN_JSON=0
CLEAN_SAVE=''
CLEAN_FROM=''
CLEAN_MAX_AGE_MIN=60

# Every type a saved row may carry, and the ones the disk apply runs rm -rf on.
CLEAN_DISK_TYPES='nm wt mise log cache pstore pw pwkeep wtnm alog'
CLEAN_RM_TYPES='nm wtnm log alog cache pw'

clean_args() {
  local d
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --all) prune_args --all; shift ;;
      --age)
        d="${2:-}"
        case "${d}" in '' | *[!0-9]*) die "clean: --age needs a number of days, e.g. --age 14" ;; esac
        disk_args --age "$((10#${d}))"
        shift 2
        ;;
      --logs) disk_args --logs "${2:-}"; shift 2 ;;
      --no-caches) CLEAN_DO_CACHES=0; shift ;;
      --json) CLEAN_JSON=1; shift ;;
      --save) CLEAN_SAVE="${2:?--save needs a file}"; shift 2 ;;
      --from) CLEAN_FROM="${2:?--from needs a file}"; shift 2 ;;
      -h | --help) clean_usage; exit 0 ;;
      *) die "clean: unknown argument: $1" ;;
    esac
  done
}

clean_usage() {
  sed -n '2,63p' "${DEVALOY_LIB}/clean.sh" | sed 's/^# \{0,1\}//'
}

# --- the context ------------------------------------------------------------
#
# The picker keeps every scan of a session in one run directory, so the disk
# view and this one must not share a target file or a flag: a disk view drawn
# from this scan would offer caches it says it did not scan. Each public
# function below re-enters itself through clean_ctx, which sets clean's flags as
# locals for the length of the call and points the disk half at its own file.
clean_ctx() { # clean_ctx <function> [args...]
  local CLEAN_IN_CTX=1 DISK_DO_DOCKER=0
  local DISK_DO_CACHES="${CLEAN_DO_CACHES}" PRUNE_BUILDER_AGE="${CLEAN_BUILDER_AGE}"
  local DISK_TARGETS
  DISK_TARGETS="$(target_file clean-disk)"
  "$@"
}

clean_vol_file() {
  target_file clean-vol
}

# --- the scan ---------------------------------------------------------------
#
# Three files. clean-disk holds the disk rows and clean-vol the volume rows,
# which is what the two halves read. `clean` holds both, which is what --save
# writes and what the picker tests to know a scan has run.
clean_scan() {
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx clean_scan "$@"; return; }
  disk_scan
  prune_scan
  awk -F'\t' '$1 == "dvol"' "$(target_file prune-vol)" >"$(clean_vol_file)"
  cat "$(disk_targets)" "$(clean_vol_file)" >"$(target_file clean)"
}

# The saved-scan half of the contract. The rows were listed to a person in
# another process, so each one is checked again here before anything reads it.
clean_load() { # clean_load <file>
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx clean_load "$@"; return; }
  local src="$1" out age type path size_kb note free_kb n=0 kept=0 reason
  [ -f "${src}" ] && [ -r "${src}" ] || die "clean: cannot read ${src}"
  age=$(($(date +%s) - $(stat -c %Y "${src}")))
  if [ "${age}" -gt $((CLEAN_MAX_AGE_MIN * 60)) ]; then
    die "clean: ${src} is $((age / 60)) minutes old, and a saved scan older than ${CLEAN_MAX_AGE_MIN} minutes is refused. Run devaloy clean --save again."
  fi

  out="$(target_file clean)"
  : >"${out}"
  while IFS=$'\t' read -r type path size_kb note free_kb || [ -n "${type}" ]; do
    n=$((n + 1))
    [ -n "${type}" ] || continue
    reason=''
    case " ${CLEAN_DISK_TYPES} dvol " in
      *" ${type} "*) ;;
      *) reason="unknown type" ;;
    esac
    # The size goes into shell arithmetic at apply, so it must be digits only.
    if [ -z "${reason}" ]; then
      case "${size_kb}" in '' | *[!0-9]*) reason="size is not a number" ;; esac
    fi
    if [ -z "${reason}" ] && [ -n "${free_kb}" ]; then
      case "${free_kb}" in *[!0-9]*) reason="free size is not a number" ;; esac
    fi
    if [ -z "${reason}" ] && [ "${type}" = "dvol" ]; then
      [[ "${path}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || reason="not a volume name"
    elif [ -z "${reason}" ]; then
      case "${path}" in
        "${DISK_ROOT}"/?*) ;;
        *) reason="not under ${DISK_ROOT}" ;;
      esac
      # Only the rm -rf types. A mise or pstore row names a protected path on
      # purpose: it is a size report, and its apply is mise prune or pnpm
      # store prune.
      if [ -z "${reason}" ]; then
        case " ${CLEAN_RM_TYPES} " in
          *" ${type} "*)
            if disk_path_protected "${path}"; then
              reason="on the never-delete list"
            fi
            ;;
        esac
      fi
    fi
    if [ -n "${reason}" ]; then
      warn "clean: dropped row ${n} (${type} ${path}): ${reason}"
      continue
    fi
    printf '%s\t%s\t%s\t%s%s\n' "${type}" "${path}" "${size_kb}" "${note}" \
      "${free_kb:+$'\t'${free_kb}}" >>"${out}"
    kept=$((kept + 1))
  done <"${src}"

  awk -F'\t' '$1 != "dvol"' "${out}" >"$(disk_targets)"
  awk -F'\t' '$1 == "dvol"' "${out}" >"$(clean_vol_file)"
  # The Docker summary is a scan, and --from runs none.
  : >"$(target_file prune)"
  warn "clean: read ${kept} row(s) from ${src}"
}

# --- reading the scan back --------------------------------------------------

clean_disk_kb() {
  local t kb=0
  for t in ${CLEAN_RM_TYPES}; do
    kb=$((kb + $(disk_sum_kb "${t}")))
  done
  printf '%s' "${kb}"
}

clean_disk_free_kb() {
  local t kb=0
  for t in ${CLEAN_RM_TYPES}; do
    kb=$((kb + $(disk_sum_free_kb "${t}")))
  done
  printf '%s' "${kb}"
}

clean_disk_paths() {
  local t n=0
  for t in ${CLEAN_RM_TYPES}; do
    n=$((n + $(disk_count "${t}")))
  done
  printf '%s' "${n}"
}

clean_total_line() {
  local dkb dfree vkb
  dkb="$(clean_disk_kb)"
  dfree="$(clean_disk_free_kb)"
  vkb="$(prune_vol_sum_kb "$(clean_vol_file)")"
  printf 'devaloy clean: the apply frees %s to %s MiB: %s to %s MiB in %s path(s) on the home volume, %s MiB in %s anonymous volume(s)\n' \
    "$(((dfree + vkb) / 1024))" "$(((dkb + vkb) / 1024))" \
    "$((dfree / 1024))" "$((dkb / 1024))" "$(clean_disk_paths)" \
    "$((vkb / 1024))" "$(prune_vol_count "$(clean_vol_file)")"
  if [ "${dfree}" -lt "${dkb}" ]; then
    echo "devaloy clean: the low figure leaves out node_modules files that another path still hard-links"
  fi
  prune_available || return 0
  echo "devaloy clean: plus Docker build cache older than ${PRUNE_BUILDER_AGE} and $([ "${PRUNE_ALL}" -eq 1 ] && printf 'unused' || printf 'dangling') images, sized in the Docker table above"
}

rows_clean() {
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx rows_clean "$@"; return; }
  local dkb dfree vkb
  dkb="$(clean_disk_kb)"
  dfree="$(clean_disk_free_kb)"
  vkb="$(prune_vol_sum_kb "$(clean_vol_file)")"
  emit_head 'clean' "scanned at $(now_stamp), age window ${DISK_AGE_DAYS}d, cache ${PRUNE_BUILDER_AGE}"
  emit_row '📦' 'node_modules' \
    "$(($(disk_count nm) + $(disk_count wtnm))) tree(s), $(disk_nm_sizes nm wtnm)"
  if [ "${DISK_DO_CACHES}" -eq 1 ]; then
    emit_row '📚' 'caches' \
      "$(($(disk_count cache) + $(disk_count pw))) path(s), $((($(disk_sum_kb cache) + $(disk_sum_kb pw)) / 1024)) MiB, plus pnpm store prune"
  else
    emit_row '📚' 'caches' 'off — --no-caches'
  fi
  emit_row '📄' 'logs' \
    "$(($(disk_count log) + $(disk_count alog))) path(s), $((($(disk_sum_kb log) + $(disk_sum_kb alog)) / 1024)) MiB"
  emit_row '🔧' 'stale mise versions' \
    "$(disk_count mise) version(s), $(($(disk_sum_kb mise) / 1024)) MiB, mise prune"
  if prune_available; then
    emit_row '🐳' 'anon volumes' \
      "$(prune_vol_count "$(clean_vol_file)") unused, $((vkb / 1024)) MiB"
    emit_row '🐳' 'build cache, images' \
      "cache older than ${PRUNE_BUILDER_AGE}, $([ "${PRUNE_ALL}" -eq 1 ] && printf 'unused' || printf 'dangling') images"
  else
    emit_row '🚫' 'docker' "$(bad 'not reachable') — the disk half still runs"
  fi
  emit_rule
  emit_row '🧹' 'total' "$(((dfree + vkb) / 1024)) to $(((dkb + vkb) / 1024)) MiB, plus build cache and images"
  emit_row '💾' 'disk now' "$(status_disk_line)"
}

# --- the report -------------------------------------------------------------
#
# The disk sections, then the Docker sections, then one total. With no daemon
# the Docker half says so and the disk half still runs.
clean_report() {
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx clean_report "$@"; return; }
  disk_report
  echo
  if prune_available; then
    prune_report "$(clean_vol_file)" || true
  else
    echo "devaloy clean: no Docker daemon reachable, so the Docker half is skipped"
  fi
  echo
  clean_total_line
}

clean_apply_targets() {
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx clean_apply_targets "$@"; return; }
  disk_apply_targets "$(disk_targets)"
  if prune_available; then
    prune_apply_targets "$(clean_vol_file)" || true
  else
    echo
    echo "devaloy clean: no Docker daemon reachable, so the Docker half is skipped"
  fi
}

# The TUI's `a`: one confirm for both halves.
clean_apply() {
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx clean_apply "$@"; return; }
  local dkb dfree vkb images='dangling images'
  dkb="$(clean_disk_kb)"
  dfree="$(clean_disk_free_kb)"
  vkb="$(prune_vol_sum_kb "$(clean_vol_file)")"
  [ "${PRUNE_ALL}" -eq 1 ] && images='every image no container is running'
  if ! confirm \
    "devaloy clean will delete $(clean_disk_paths) path(s) on the home volume and $(prune_vol_count "$(clean_vol_file)") anonymous volume(s)," \
    "freeing $(((dfree + vkb) / 1024)) to $(((dkb + vkb) / 1024)) MiB$([ "$(disk_count mise)" -gt 0 ] && printf ', run mise prune')$([ "${DISK_DO_CACHES}" -eq 1 ] && printf ', run pnpm store prune and npm cache clean')," \
    "and drop Docker build cache older than ${PRUNE_BUILDER_AGE} and ${images}." \
    "It deletes only what the report listed. Worktrees and named volumes are never deleted."; then
    printf '\n  cancelled\n'
    sleep 1
    return 0
  fi
  APPLY=1
  run_raw clean_apply_targets
  APPLY=0
}

# --- the machine report -----------------------------------------------------
#
# Built from the TSV files, which stay the internal format. See the schema in
# the header.
clean_json() {
  [ -n "${CLEAN_IN_CTX:-}" ] || { clean_ctx clean_json "$@"; return; }
  local avail=false
  prune_available && avail=true
  jq -n \
    --rawfile disk "$(disk_targets)" \
    --rawfile vols "$(clean_vol_file)" \
    --rawfile summary "$(target_file prune)" \
    --argjson available "${avail}" \
    --arg rm_types "${CLEAN_RM_TYPES}" '
    def lines($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    def rows($s): lines($s) | map(((.[2] // "0") | tonumber? // 0) as $kb
      | {type: .[0], path: .[1], size_kb: $kb, note: (.[3] // ""),
         min_free_kb: ((.[4] // "") | tonumber? // $kb)});
    ($rm_types | split(" ")) as $rm
    | rows($disk) as $d
    | rows($vols) as $v
    | ($d | map(select(.type as $t | $rm | index($t)))) as $del
    | ($del | map(.size_kb) | add // 0) as $dkb
    | ($del | map(.min_free_kb) | add // 0) as $dfree
    | ($v | map(.size_kb) | add // 0) as $vkb
    | {
        disk: $d,
        docker: {
          available: $available,
          summary: (if $available then lines($summary) | map(select(.[0] != "none")
            | {type: .[0], count: ((.[1] | tonumber?) // .[1]), size: .[2], reclaimable: (.[3] // "")}) else [] end),
          volumes: $v
        },
        totals: {
          disk_paths: ($del | length),
          disk_kb: $dkb,
          volumes: ($v | length),
          volume_kb: $vkb,
          total_kb: ($dkb + $vkb),
          total_mib: (($dkb + $vkb) / 1024 | floor),
          disk_min_free_kb: $dfree,
          total_min_free_kb: ($dfree + $vkb),
          total_min_free_mib: (($dfree + $vkb) / 1024 | floor)
        }
      }'
}

do_clean() {
  clean_args "$@"
  clean_ctx clean_run
}

clean_run() {
  if [ -n "${CLEAN_FROM}" ]; then
    clean_load "${CLEAN_FROM}"
  else
    clean_scan
  fi

  if [ -n "${CLEAN_SAVE}" ]; then
    cat "$(target_file clean)" >"${CLEAN_SAVE}"
    warn "clean: saved $(wc -l <"$(target_file clean)" | tr -d ' ') row(s) to ${CLEAN_SAVE}"
  fi

  if [ "${CLEAN_JSON}" -eq 1 ]; then
    [ "${APPLY}" -eq 1 ] && clean_apply_targets >&2
    clean_json
    return 0
  fi

  clean_report
  clean_apply_targets
  if [ "${APPLY}" -eq 0 ]; then
    echo
    echo "devaloy clean: dry run. Nothing was deleted. Pass --apply to act."
  fi
}
