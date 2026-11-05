#!/usr/bin/env bash
# devaloy: reclaim disk from the nested Docker daemon, by hand.
#
# Only useful on a box built with WITH_DOCKER=true. Project stacks accumulate
# build cache and old image layers in the docker-data volume, and nothing on
# this box reaps them for you.
#
# THIS IS DELIBERATELY NOT ON A TIMER, and the host is not a precedent. The
# Docker host runs a docker-prune.timer (see scripts/host-resource-guard.sh)
# because a host runs services, whose images are pinned by the containers using
# them. This box runs an agent that may be halfway through a multi-stage build,
# whose intermediate images are pinned by nothing at all. Build cache is safe to
# reap automatically and does get reaped automatically, by the builder GC in
# config/docker/daemon.json. Images are not, which is why removing them is a
# command you type.
#
# Usage: devaloy prune [--apply] [--all] [--age <dur>] [--builder-age <dur>]
#   --apply              actually prune. Without it, this only reports.
#   --all                also remove images no container uses, not just dangling
#   --age <dur>          only touch images older than this. Default 168h (7 days).
#   --builder-age <dur>  only touch build cache older than this. Default 168h.
#
# What it removes: build cache older than --builder-age, dangling images (every
# unused image with --all) older than --age, and each anonymous volume that no
# container uses. Named volumes are never listed, so a compose stack's database
# volume survives a prune even when the stack is down.
#
# WHY A SEPARATE --builder-age. The builder GC in config/docker/daemon.json
# always keeps defaultReservedSpace (10GB) of cache, so it never frees a cache
# under 10GB. On this box the age filter here is what frees a smaller cache.
#
# NOTE ON --apply. The old devaloy-prune pruned as soon as you ran it; there was
# no dry run. It has one now, so every verb answers to the same contract and the
# TUI can show you the reclaim before it happens. `devaloy prune --apply` is the
# old behaviour.

PRUNE_AGE="168h"
PRUNE_BUILDER_AGE="168h"
PRUNE_ALL=0

# The label the daemon (Docker 23+) puts on every volume it creates for an
# anonymous mount (`-v /data`, a Dockerfile VOLUME). It is the same test
# `docker volume prune` without -a uses, and it is the reason a named volume can
# never land in the list: a name you gave, or compose gave, carries no such label.
PRUNE_ANON_LABEL='com.docker.volume.anonymous'

prune_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --all) PRUNE_ALL=1; shift ;;
      --age) PRUNE_AGE="${2:?--age needs a duration, e.g. 72h}"; shift 2 ;;
      --builder-age)
        PRUNE_BUILDER_AGE="${2:?--builder-age needs a duration, e.g. 24h}"
        shift 2
        ;;
      -h | --help) prune_usage; exit 0 ;;
      *) die "prune: unknown argument: $1" ;;
    esac
  done
}

prune_usage() {
  sed -n '2,36p' "${DEVALOY_LIB}/prune.sh" | sed 's/^# \{0,1\}//'
}

prune_available() {
  docker info >/dev/null 2>&1
}

# --- the scan -------------------------------------------------------------
#
# Docker's own accounting is the scan. `docker system df` already reports what
# is reclaimable per resource type, so walking anything by hand here would be
# reimplementing it worse.
#
# Two target files. `prune` holds the `docker system df` summary, one line per
# resource type, for the report only. `prune-vol` holds one row per volume the
# apply removes, in the disk row format (TYPE, PATH, SIZE_KB, NOTE,
# tab-separated): TYPE is `dvol`, PATH is the volume name. `devaloy clean` reads
# and saves that file, so its format is the disk format, not a new one.
prune_scan() {
  local out vout
  out="$(target_file prune)"
  vout="$(target_file prune-vol)"
  : >"${out}"
  : >"${vout}"
  prune_available || { printf 'none\t-\t0\tno Docker daemon reachable\n' >>"${out}"; return 0; }
  docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}' \
    2>/dev/null >>"${out}" || true
  prune_scan_volumes "${vout}"
}

# Anonymous volumes (see PRUNE_ANON_LABEL) that no container uses, running or
# stopped: `dangling=true` is Docker's own "no container references it".
#
# The size comes from `docker system df -v`, the only place Docker reports it.
# It prints a decimal unit string ("307.2kB", "1.5GB"), which jq turns into KiB
# so the row matches `du -sk` in the disk rows. A volume df cannot size gets 0
# and says so; it is still listed, because the size is a report, not the test.
prune_scan_volumes() { # prune_scan_volumes <out file>
  local vout="$1" sizes name size_kb created note
  sizes="$(docker system df -v --format json 2>/dev/null | jq -r '
    def kb: capture("^(?<n>[0-9.]+)\\s*(?<u>[A-Za-z]*)$")
      | (.n | tonumber) * ({"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6,
          "GB": 1e9, "TB": 1e12, "PB": 1e15}[.u] // 1) / 1024 | floor;
    .Volumes[]? | [.Name, ((.Size | kb) // 0)] | @tsv' 2>/dev/null || true)"
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    size_kb="$(printf '%s\n' "${sizes}" | awk -F'\t' -v n="${name}" \
      '$1 == n { print $2; exit }')"
    note='anonymous, no container'
    if [ -z "${size_kb}" ]; then
      size_kb=0
      note="${note}, size unknown"
    fi
    created="$(docker volume inspect --format '{{.CreatedAt}}' "${name}" 2>/dev/null || true)"
    [ -n "${created}" ] && note="${note}, created ${created%%T*}"
    printf 'dvol\t%s\t%s\t%s\n' "${name}" "${size_kb}" "${note}" >>"${vout}"
  done < <(docker volume ls -q --filter dangling=true \
    --filter "label=${PRUNE_ANON_LABEL}" 2>/dev/null || true)
}

prune_vol_count() { # prune_vol_count <file>
  awk -F'\t' '$1 == "dvol"' "$1" 2>/dev/null | wc -l | tr -d ' '
}

prune_vol_sum_kb() { # prune_vol_sum_kb <file>
  awk -F'\t' '$1 == "dvol" { s += $3 } END { print s + 0 }' "$1" 2>/dev/null || echo 0
}

rows_prune() {
  emit_head 'docker' "scanned at $(now_stamp), images ${PRUNE_AGE}, cache ${PRUNE_BUILDER_AGE}"
  if ! prune_available; then
    emit_row '🚫' 'daemon' "$(bad 'not reachable')"
    case "$(build_flag WITH_DOCKER)" in
      false) emit_hint "${DIM}this box was not built with WITH_DOCKER${RESET}" ;;
      *) emit_hint "${DIM}read the end of /var/log/dockerd.log${RESET}" ;;
    esac
    return 0
  fi
  local type count size reclaim
  while IFS=$'\t' read -r type count size reclaim; do
    [ -n "${type}" ] || continue
    emit_row '🐳' "${type}" "${count}, ${size} — ${reclaim} reclaimable"
  done <"$(target_file prune)"
  local vfile
  vfile="$(target_file prune-vol)"
  emit_row '🐳' 'anon volumes' \
    "$(prune_vol_count "${vfile}") unused, $(($(prune_vol_sum_kb "${vfile}") / 1024)) MiB"
  if [ "${PRUNE_ALL}" -eq 1 ]; then
    emit_hint "${YELLOW}--all${RESET}${DIM} — takes images no container is running${RESET}"
  else
    emit_hint "${DIM}dangling images only; devaloy prune --all takes more${RESET}"
  fi
}

prune_report() { # prune_report [volume rows file]
  if ! prune_available; then
    echo "devaloy prune: no Docker daemon reachable." >&2
    echo "devaloy prune: this box needs WITH_DOCKER=true and a rebuild; if it has" >&2
    echo "devaloy prune: that, read the end of /var/log/dockerd.log." >&2
    return 1
  fi
  echo "devaloy prune: disk before"
  docker system df

  local vfile="${1:-$(target_file prune-vol)}" type name size_kb note
  echo
  echo "devaloy prune: anonymous volumes no container uses (named volumes are never listed)"
  if [ "$(prune_vol_count "${vfile}")" -eq 0 ]; then
    echo "  none"
  else
    while IFS=$'\t' read -r type name size_kb note; do
      [ "${type}" = "dvol" ] || continue
      printf '  %6s MiB  %s\n' "$((size_kb / 1024))" "${name}"
      printf '               %s\n' "${note}"
    done <"${vfile}"
    printf 'devaloy prune: %s volume(s), %s MiB\n' \
      "$(prune_vol_count "${vfile}")" "$(($(prune_vol_sum_kb "${vfile}") / 1024))"
  fi
}

# Removes each `dvol` row in <file>, one `docker volume rm` per row. Never
# `docker volume prune`: that takes every unused anonymous volume at apply time,
# including one that appeared after the scan, and the contract is that only the
# listed rows go. `devaloy clean --apply --from` calls this with a saved file.
#
# Before each rm it checks the volume still carries PRUNE_ANON_LABEL, so a row
# edited (or saved) to name a named volume is refused, not removed. Docker
# itself refuses a volume a container uses; that is reported and the loop moves
# on. Rows of other types are ignored.
prune_apply_volumes() { # prune_apply_volumes <file>
  local file="$1" type name size_kb note labels n=0
  [ -r "${file}" ] || return 0
  while IFS=$'\t' read -r type name size_kb note; do
    [ "${type}" = "dvol" ] || continue
    [ -n "${name}" ] || continue
    n=$((n + 1))
    labels="$(docker volume inspect --format \
      '{{range $k, $v := .Labels}}{{$k}}{{"\n"}}{{end}}' -- "${name}" 2>/dev/null)" || {
      echo "devaloy prune: volume ${name} is gone, skipped"
      continue
    }
    if ! printf '%s\n' "${labels}" | grep -qxF "${PRUNE_ANON_LABEL}"; then
      echo "devaloy prune: volume ${name} is not anonymous, refused"
      continue
    fi
    if [ "${APPLY}" -eq 1 ]; then
      if docker volume rm -- "${name}" >/dev/null 2>&1; then
        echo "devaloy prune: removed volume ${name}"
      else
        echo "devaloy prune: Docker refused to remove volume ${name} (in use?), skipped"
      fi
    else
      echo "devaloy prune: would remove volume ${name}"
    fi
  done <"${file}"
  [ "${n}" -gt 0 ] || echo "devaloy prune: no anonymous volumes to remove"
}

# The volume rows default to this scan's own file. `devaloy clean` passes its
# own, which with --from holds the rows of a saved scan.
prune_apply_targets() { # prune_apply_targets [volume rows file]
  local vfile="${1:-$(target_file prune-vol)}"
  prune_available || return 1

  # Build cache first, because it is both the biggest share of the waste and the
  # only part that is free to lose — a discarded layer costs a rebuild, never a
  # pull.
  echo
  if [ "${APPLY}" -eq 1 ]; then
    echo "devaloy prune: pruning build cache older than ${PRUNE_BUILDER_AGE}"
    docker builder prune --force --filter "until=${PRUNE_BUILDER_AGE}"
  else
    echo "devaloy prune: would prune build cache older than ${PRUNE_BUILDER_AGE}"
  fi

  # Neither of these can touch an image a running container uses: Docker
  # refuses, so a stack you left up is safe by construction rather than by a
  # check here. --all is still the wider blade — it takes images nothing is
  # running, which on this box includes the base image of a stack you stopped
  # yesterday.
  echo
  if [ "${PRUNE_ALL}" -eq 1 ]; then
    if [ "${APPLY}" -eq 1 ]; then
      echo "devaloy prune: removing unused images older than ${PRUNE_AGE} (--all)"
      docker image prune --all --force --filter "until=${PRUNE_AGE}"
    else
      echo "devaloy prune: would remove unused images older than ${PRUNE_AGE} (--all)"
    fi
  else
    if [ "${APPLY}" -eq 1 ]; then
      echo "devaloy prune: removing dangling images older than ${PRUNE_AGE}"
      echo "devaloy prune: (pass --all to also take images no container is running)"
      docker image prune --force --filter "until=${PRUNE_AGE}"
    else
      echo "devaloy prune: would remove dangling images older than ${PRUNE_AGE}"
      echo "devaloy prune: (pass --all to also take images no container is running)"
    fi
  fi

  # Volumes last, and only the rows the scan wrote.
  echo
  prune_apply_volumes "${vfile}"

  if [ "${APPLY}" -eq 1 ]; then
    echo
    echo "devaloy prune: disk after"
    docker system df
  fi
}

prune_apply() {
  prune_available || {
    printf '\n  no Docker daemon on this box\n'
    sleep 1
    return 0
  }
  local blade='dangling images'
  [ "${PRUNE_ALL}" -eq 1 ] && blade='every image no container is running'
  if ! confirm \
    "devaloy prune will drop build cache older than ${PRUNE_BUILDER_AGE}, ${blade}" \
    "older than ${PRUNE_AGE}, and $(prune_vol_count "$(target_file prune-vol)") anonymous volume(s) no container uses." \
    "Docker refuses to touch an image or volume a container uses. A dropped layer" \
    "costs a rebuild or a pull. A dropped volume's data is gone; named volumes stay."; then
    printf '\n  cancelled\n'
    sleep 1
    return 0
  fi
  APPLY=1
  run_raw prune_apply_targets
  APPLY=0
}

do_prune() {
  prune_args "$@"
  prune_scan
  prune_report || return 1
  prune_apply_targets
  if [ "${APPLY}" -eq 0 ]; then
    echo
    echo "devaloy prune: report only. Nothing was pruned. Pass --apply to act."
  fi
}
