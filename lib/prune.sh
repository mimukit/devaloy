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
# Usage: devaloy prune [--apply] [--all] [--age <duration>]
#   --apply        actually prune. Without it, this only reports.
#   --all          also remove images no container uses, not just dangling ones
#   --age <dur>    only touch things older than this. Default 168h (7 days).
#
# NOTE ON --apply. The old devaloy-prune pruned as soon as you ran it; there was
# no dry run. It has one now, so every verb answers to the same contract and the
# TUI can show you the reclaim before it happens. `devaloy prune --apply` is the
# old behaviour.

PRUNE_AGE="168h"
PRUNE_ALL=0

prune_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --all) PRUNE_ALL=1; shift ;;
      --age) PRUNE_AGE="${2:?--age needs a duration, e.g. 72h}"; shift 2 ;;
      -h | --help) prune_usage; exit 0 ;;
      *) die "prune: unknown argument: $1" ;;
    esac
  done
}

prune_usage() {
  sed -n '2,26p' "${DEVALOY_LIB}/prune.sh" | sed 's/^# \{0,1\}//'
}

prune_available() {
  docker info >/dev/null 2>&1
}

# --- the scan -------------------------------------------------------------
#
# Docker's own accounting is the scan. `docker system df` already reports what
# is reclaimable per resource type, so walking anything by hand here would be
# reimplementing it worse.
prune_scan() {
  local out
  out="$(target_file prune)"
  : >"${out}"
  prune_available || { printf 'none\t-\t0\tno Docker daemon reachable\n' >>"${out}"; return 0; }
  docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}' \
    2>/dev/null >>"${out}" || true
}

rows_prune() {
  emit_head 'docker' "scanned at $(now_stamp), age window ${PRUNE_AGE}"
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
  if [ "${PRUNE_ALL}" -eq 1 ]; then
    emit_hint "${YELLOW}--all${RESET}${DIM} — takes images no container is running${RESET}"
  else
    emit_hint "${DIM}dangling images only; devaloy prune --all takes more${RESET}"
  fi
}

prune_report() {
  if ! prune_available; then
    echo "devaloy prune: no Docker daemon reachable." >&2
    echo "devaloy prune: this box needs WITH_DOCKER=true and a rebuild; if it has" >&2
    echo "devaloy prune: that, read the end of /var/log/dockerd.log." >&2
    return 1
  fi
  echo "devaloy prune: disk before"
  docker system df
}

prune_apply_targets() {
  prune_available || return 1

  # Build cache first, because it is both the biggest share of the waste and the
  # only part that is free to lose — a discarded layer costs a rebuild, never a
  # pull.
  echo
  if [ "${APPLY}" -eq 1 ]; then
    echo "devaloy prune: pruning build cache older than ${PRUNE_AGE}"
    docker builder prune --force --filter "until=${PRUNE_AGE}"
  else
    echo "devaloy prune: would prune build cache older than ${PRUNE_AGE}"
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
    "devaloy prune will drop build cache and ${blade} older than ${PRUNE_AGE}." \
    "Docker refuses to touch an image a running container uses, so a stack you" \
    "left up is safe. A dropped layer costs a rebuild or a pull, never data."; then
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
