#!/usr/bin/env bash
# devaloy: helpers shared by more than one verb.
#
# Sourced by `devaloy`, never executed. Nothing here prints unless it is asked
# to, so a module can call any of it while building a row.
#
# The rule for what belongs here: it is used by two or more modules. A helper
# only `disk.sh` calls lives in `disk.sh`, where the reader looking at the disk
# reclaim finds it without opening a second file.

# --- output ---------------------------------------------------------------
#
# fzf runs every binding with stdout on a pipe, so `test -t 1` is false in
# exactly the places that do want colour. Key off NO_COLOR alone, as the ip
# script does, and let --ansi render the escapes.
if [ -z "${NO_COLOR:-}" ]; then
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  DIM='' BOLD='' RED='' GREEN='' YELLOW='' RESET=''
fi

die() {
  printf 'devaloy: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'devaloy: %s\n' "$1" >&2
}

require() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "needs ${cmd} on PATH"
  done
}

shq() {
  printf '%q' "$1"
}

# --- the destructive gate -------------------------------------------------
#
# Every destructive path goes through here, so the dry run and the real run
# cannot drift apart. There is no second code path to forget to guard.
#
# APPLY is set by the argument parser in `devaloy` and by the TUI's confirm. It
# is deliberately a global rather than a parameter: a helper five calls deep
# must not be able to act while the caller believes it is reporting.
APPLY="${APPLY:-0}"

act() {
  if [ "${APPLY}" -eq 1 ]; then
    "$@"
  fi
}

# --- the target file ------------------------------------------------------
#
# The two-phase contract. A scan writes the things it intends to touch here,
# the report prints from this file, and the apply consumes this same file. The
# list you approved is the list that runs, which is the whole point: a second
# `find` between the report and the confirm could turn up a node_modules tree
# you never saw listed.
#
# One line per target. `disk.sh` writes a path; `ram.sh` writes
# "<pid> <start-time>" so the apply can prove the PID was not reused.
#
# MADE EAGERLY, AT SOURCE TIME, and that is not a style choice. The lazy version
# (`rundir` creating the directory on first call) is broken here: `target_file`
# is always called from a command substitution, so the assignment lands in a
# subshell, the parent never sees it, and every call makes a *new* directory
# that the subshell's own EXIT trap then deletes. The scan wrote to a path that
# no longer existed by the time the report read it.
DEVALOY_RUNDIR="$(mktemp -d -t devaloy.XXXXXX)"
# Only the top-level shell removes it. A subshell inherits the trap but exits
# without running it, because the trap is on the parent's EXIT.
trap 'rm -rf "${DEVALOY_RUNDIR}"' EXIT

rundir() {
  printf '%s' "${DEVALOY_RUNDIR}"
}

target_file() { # target_file <name>
  printf '%s/%s.targets' "$(rundir)" "$1"
}

target_count() { # target_count <name>
  local f
  f="$(target_file "$1")"
  [ -s "${f}" ] || { printf '0'; return; }
  wc -l <"${f}" | tr -d ' '
}

# --- the cgroup -----------------------------------------------------------
#
# `free` inside a container reports the HOST's memory, not this container's, so
# it is the wrong number to act on when the whole point is a per-container
# mem_limit. These files are the container's own accounting. cgroup v2 only —
# v1 spells them differently, and every devaloy host this was written for
# reports cgroup2fs (check with `stat -fc %T /sys/fs/cgroup/`).
CG=/sys/fs/cgroup

read_cg() { # read_cg <file name>
  # Prints the value, or an empty string when the file is missing (cgroup v1)
  # or reads "max" (no limit set).
  [ -r "${CG}/$1" ] || return 0
  local v
  v="$(cat "${CG}/$1" 2>/dev/null || true)"
  [ "${v}" = "max" ] && return 0
  printf '%s' "${v}"
}

human() { # human <bytes>
  # bytes -> MiB, integer. Deliberately not `numfmt`: this needs to work the
  # same in the minimal shell the entrypoint uses.
  local b="${1:-}"
  [ -z "${b}" ] && { printf 'unlimited'; return; }
  printf '%s MiB' "$((b / 1024 / 1024))"
}

mem_percent() {
  # Prints the percentage of the ceiling in use, or nothing when no mem_limit
  # is set. Callers decide what to say about an empty answer.
  local cur max
  cur="$(read_cg memory.current)"
  max="$(read_cg memory.max)"
  [ -n "${cur}" ] && [ -n "${max}" ] || return 0
  printf '%s' "$((cur * 100 / max))"
}

# --- the Paseo daemon -----------------------------------------------------
#
# Read by `status.sh`, `ram.sh` and `doctor.sh`, which is why it is here rather
# than in the module that kills it.
#
# THE PATTERN IS -xf AND IT IS CAPITALISED, and both matter. devaloy-ram used
# `pgrep -f 'paseo daemon'` and that was wrong twice on a live box:
#
#   Wrong case.  Paseo sets its process title to `Paseo Daemon`. pgrep -f is
#                case-sensitive, so the lowercase pattern never matched the
#                daemon, and the reclaim that pays for the whole command
#                reported "no Paseo daemon running" while it was running.
#   Self-match.  A substring -f pattern matches the command line of the shell
#                running the script, because that command line contains the
#                script's own text. So the pattern found devaloy instead, and
#                `pkill -f` on it would have TERMed devaloy's own process tree.
#
# -x anchors the match to the whole command line, which excludes both the
# invoking shell and any editor with the string in a buffer.
PASEO_DAEMON_TITLE='Paseo Daemon'

paseo_pids() {
  pgrep -xf "${PASEO_DAEMON_TITLE}" 2>/dev/null || true
}

# The supervisor's own RSS is a rounding error — measured at 66 MiB on a box
# where the restart reclaimed 3.2 GiB. The memory is in its CHILDREN: the daemon
# parents every pane, every agent session and every worker it spawns, and those
# are what die with it. Reporting the supervisor alone makes the restart look
# pointless, which is the opposite of true.
#
# Walks the tree breadth-first from the supervisor PIDs. A depth cap is not
# needed — ps output is a finite set and each PID is visited once.
paseo_tree() { # paseo_tree <root pids>
  local frontier="$1" seen="" next pid
  while [ -n "${frontier}" ]; do
    seen="${seen} ${frontier}"
    next=""
    for pid in ${frontier}; do
      next="${next} $(pgrep -P "${pid}" 2>/dev/null | tr '\n' ' ')"
    done
    frontier="$(echo "${next}" | tr ' ' '\n' | grep -v '^$' || true)"
  done
  echo "${seen}" | tr ' ' '\n' | grep -v '^$' | sort -un
}

paseo_rss_mib() { # paseo_rss_mib <pid list>
  local pid rss total=0
  for pid in $1; do
    rss="$(awk '/^VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
    [ -n "${rss}" ] && total=$((total + rss))
  done
  printf '%s' "$((total / 1024))"
}

# This process runs inside a Paseo pane, so a Paseo restart kills the terminal
# reading its output. The confirm in the TUI says so; it does not refuse.
in_paseo_pane() {
  [ -n "${PASEO_AGENT_ID:-}" ]
}

# --- process age ----------------------------------------------------------
#
# From the mtime of /proc/<pid>, which the kernel sets at process start.
# `ps -o etimes` is the obvious choice and it is WRONG here: it derives elapsed
# time from the host boot clock, and inside a container on a host that has been
# suspended or migrated it returns nonsense. Measured on this box it reported
# 4121799776 seconds — 130 years — for every process, which passes any age test
# you write and turns the guard into a no-op.
#
# The same number is the reuse guard. A PID recorded at scan time and re-read at
# apply time is only the same process when this value matches.
proc_started() { # proc_started <pid>
  stat -c %Y "/proc/$1" 2>/dev/null || true
}

# --- the build flags ------------------------------------------------------
#
# Written by the Dockerfile, because the build args are only in scope there.
# WITH_PASEO is deliberately NOT in the file: it is a runtime variable that
# `docker compose up -d` can flip without a rebuild, so reading it from a file
# baked into the image would report the wrong answer.
BUILD_FLAGS_FILE="${BUILD_FLAGS_FILE:-/opt/devaloy/build-flags}"

build_flag() { # build_flag <name>
  # Prints true or false. An image built before this file existed reports
  # "unknown", which doctor renders as a row rather than treating as a fault.
  [ -r "${BUILD_FLAGS_FILE}" ] || { printf 'unknown'; return; }
  local v
  v="$(sed -n "s/^$1=//p" "${BUILD_FLAGS_FILE}" 2>/dev/null | head -1)"
  printf '%s' "${v:-unknown}"
}

toolset_revision() {
  local marker="${HOME}/.local/share/mise/.devaloy-bootstrapped"
  [ -r "${marker}" ] && head -1 "${marker}" 2>/dev/null || printf 'not bootstrapped'
}

now_stamp() {
  date +%H:%M:%S
}

refuse_root() { # refuse_root <verb>
  # update and nvim-sync both refuse root, and for the same reason: root writes
  # the files with the wrong owner and leaves the dev user unable to edit its
  # own toolchain or editor config.
  [ "$(id -un)" = "root" ] || return 0
  die "$1: run this as the dev user, not root."
}
