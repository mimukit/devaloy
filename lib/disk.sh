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
#                     [--logs <days>]
#   --apply        actually delete. Without it, this only lists.
#   --age <days>   a node_modules must be untouched this long to qualify.
#                  Default 30.
#   --docker       also hand off to the docker reclaim at the end
#   --caches       also clear the pnpm/npm/mise/turbo download caches, run
#                  pnpm store prune (the store itself is never deleted), and
#                  remove Playwright browser revisions that no installed
#                  playwright-core names in its browsers.json
#   --logs <days>  also remove agent logs older than <days> (7 or more):
#                  ~/.codex/sessions/**/*.jsonl, each Claude session
#                  ~/.claude/projects/*/<uuid>.jsonl with its <uuid>/
#                  directory, and files under ~/.t3/userdata/logs. A deleted
#                  session can no longer be resumed. Off by default.
#
# A linked worktree's node_modules is removed whatever its age when the
# worktree is clean, has no commit missing from every remote, and no process
# has its cwd in it. The apply checks all three again before it deletes.
#
# Never deleted, whatever a row says: the pnpm store, the aube store and its
# virtual store, mise installs (mise prune only), and Claude agent memory. See
# DISK_PROTECTED in lib/disk.sh.

DISK_AGE_DAYS=30
DISK_DO_DOCKER=0
DISK_DO_CACHES=0
DISK_LOGS_DAYS=''
DISK_ROOT="${HOME:-/home/dev}"
# Empty means the default target file. `devaloy clean` sets it, as a local, to a
# file of its own, so its scan never stands in for the disk view's.
DISK_TARGETS=''

disk_targets() { # the file the disk scan writes and everything else reads
  printf '%s' "${DISK_TARGETS:-$(target_file disk)}"
}

# --- the never-delete list --------------------------------------------------
#
# One list, one check. disk_apply_targets refuses any path row that is under
# one of these, or that has one of these under it, so a scan bug or a saved
# scan edited by hand cannot take a store with it. Each entry is a case
# pattern, so `*` matches a directory name.
#
#   pnpm store      pruned with `pnpm store prune`, never rm -rf. Deleting it
#                   breaks every project's install at once.
#   aube            mise npm tools symlink into ~/.cache/aube/virtual-store,
#                   so deleting either half breaks claude, codex and the rest.
#   mise data       stale versions go through `mise prune` and nothing else.
#   agent memory    Claude Code's per-project memory is not a log.
DISK_PROTECTED=(
  "${DISK_ROOT}/.local/share/pnpm/store"
  "${DISK_ROOT}/.local/share/aube"
  "${DISK_ROOT}/.cache/aube"
  "${DISK_ROOT}/.local/share/mise"
  "${DISK_ROOT}/.claude/projects/*/memory"
)

disk_path_protected() { # disk_path_protected <path>
  # Returns 0 (protected) when <path> is a protected path, is under one, or
  # holds one. A path with a `..` component is refused outright, because the
  # textual test below cannot see where it resolves.
  local p="${1%/}" pat up
  [ -n "${p}" ] || return 0
  case "/${p}/" in */../*) return 0 ;; esac
  for pat in "${DISK_PROTECTED[@]}"; do
    # The patterns are unquoted on purpose so their `*` globs.
    # shellcheck disable=SC2254
    case "${p}/" in ${pat}/*) return 0 ;; esac
    # Each ancestor of the pattern: a row for ~/.claude/projects/x would take
    # ~/.claude/projects/x/memory with it. A case `*` also matches `/`, so
    # the ancestor must have as many components as <path>. Without that test
    # ~/.claude/projects/* matched ~/.claude/projects/x/<uuid>.jsonl, which
    # holds no memory directory.
    up="${pat}"
    while [ "${up}" != "${up%/*}" ]; do
      up="${up%/*}"
      [ -n "${up}" ] || break
      [ "${p//[!\/]/}" = "${up//[!\/]/}" ] || continue
      # shellcheck disable=SC2254
      case "${p}" in ${up}) return 0 ;; esac
    done
  done
  return 1
}

disk_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --age) DISK_AGE_DAYS="${2:?--age needs a number of days, e.g. 14}"; shift 2 ;;
      --docker) DISK_DO_DOCKER=1; shift ;;
      --caches) DISK_DO_CACHES=1; shift ;;
      --logs)
        # A floor of 7: a session from this week is one you may still resume.
        case "${2:-}" in
          '' | *[!0-9]*) die "disk: --logs needs a number of days, 7 or more, e.g. --logs 30" ;;
        esac
        [ "$((10#$2))" -ge 7 ] || die "disk: --logs $2 is under the floor of 7 days"
        DISK_LOGS_DAYS="$((10#$2))"
        shift 2
        ;;
      -h | --help) disk_usage; exit 0 ;;
      *) die "disk: unknown argument: $1" ;;
    esac
  done
}

disk_usage() {
  sed -n '2,49p' "${DEVALOY_LIB}/disk.sh" | sed 's/^# \{0,1\}//'
}

# --- the scan -------------------------------------------------------------
#
# Writes one tab-delimited line per target: TYPE, PATH, SIZE_KB, NOTE, and for
# the nm and wtnm types a fifth column, FREE_KB (see disk_measure). TYPE decides
# what the apply does with it, so a new kind of reclaim is a new type here and a
# new case in disk_apply, with the report needing no change.
#
# A row with FREE_KB must have a NOTE that is not empty. Tab is whitespace to
# `read`, so an empty NOTE would let FREE_KB slide into its place.

# THE SIZE OF A node_modules IS TWO NUMBERS. pnpm hard-links each file from its
# store, and deleting a link frees the bytes only when no other path still holds
# the file. `du -sk` counts every file once, so a pnpm tree reads as the space
# the delete frees when most of it stays on the disk under the store. On the
# reference box one 3758 MiB tree held 130 MiB in files with a link count of 1.
#
# One walk gives both: KB, what `du -sk` reports, and FREE_KB, the blocks of
# directories and of files no other path links. FREE_KB is a lower bound. A file
# whose every link is inside the trees deleted together is freed too, but no
# walk of one tree can know that.
disk_measure() { # disk_measure <dir> -> "<kb> <free_kb>"
  find "$1" -xdev -printf '%y %n %i %k\n' 2>/dev/null | awk '
    !seen[$3]++ { kb += $4; if ($1 == "d" || $2 == 1) free += $4 }
    END { print kb + 0, free + 0 }'
}

disk_scan() {
  local out
  out="$(disk_targets)"
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
  local nm size_kb free_kb project last_commit
  while IFS= read -r nm; do
    [ -n "${nm}" ] || continue
    read -r size_kb free_kb < <(disk_measure "${nm}")
    [ "${size_kb:-0}" -gt 0 ] || continue
    project="$(dirname "${nm}")"
    last_commit="$(git -C "${project}" log -1 --format=%cr 2>/dev/null || true)"
    [ -n "${last_commit}" ] || last_commit="not a git repo"
    printf 'nm\t%s\t%s\tlast commit: %s\t%s\n' \
      "${nm}" "${size_kb}" "${last_commit}" "${free_kb}" >>"${out}"
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
    if [ "${extra:-0}" -gt 0 ]; then
      disk_scan_wtnm "${out}" "${repo}"
    fi
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
  # It is therefore the one target that is NOT a path: the row records the
  # version so the report can show its size, and the apply runs `mise prune`
  # once, for the tools the rows name.
  #
  # The rows come from `mise ls --prunable --json`, which applies the same
  # tracked-configs rule as `mise prune`, so the report lists the versions the
  # prune removes and nothing else. Listing every install directory instead put
  # tools with one version under a "stale" heading. The JSON is an object of
  # tool name to an array of {version, install_path}, and `{}` when nothing is
  # prunable.
  if command -v mise >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local tool version path
    while IFS=$'\t' read -r tool version path; do
      [ -n "${path}" ] && [ -d "${path}" ] || continue
      size_kb="$(du -sk "${path}" 2>/dev/null | cut -f1)"
      printf 'mise\t%s\t%s\t%s@%s\n' \
        "${path}" "${size_kb:-0}" "${tool}" "${version}" >>"${out}"
    done < <(mise ls --prunable --json 2>/dev/null |
      jq -r 'to_entries[] | .key as $t | .value[] | [$t, .version, .install_path] | @tsv' 2>/dev/null |
      sort)
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

  # --- agent logs ---------------------------------------------------------
  #
  # Opt-in through --logs <days>, because a deleted session can no longer be
  # resumed. See disk_scan_logs.
  if [ -n "${DISK_LOGS_DAYS}" ]; then
    disk_scan_logs "${out}"
  fi

  # --- caches -------------------------------------------------------------
  #
  # Opt-in because every one of these costs a re-download on the next install,
  # and on a box behind Tailscale that is minutes rather than seconds. Worth it
  # when the disk is genuinely full, wasteful otherwise.
  #
  # Not ~/.npm as a whole: `npm cache clean --force` at apply clears
  # ~/.npm/_cacache, and the rest of ~/.npm is npm's own state and logs.
  if [ "${DISK_DO_CACHES}" -eq 1 ]; then
    local c
    for c in "${DISK_ROOT}/.cache/pnpm" "${DISK_ROOT}/.npm/_npx" \
      "${DISK_ROOT}/.local/share/pnpm/package-manager-store" \
      "${DISK_ROOT}/.cache/mise" "${DISK_ROOT}/.cache/turbo"; do
      [ -d "${c}" ] || continue
      printf 'cache\t%s\t%s\tpackage manager cache\n' \
        "${c}" "$(du -sk "${c}" 2>/dev/null | cut -f1)" >>"${out}"
    done

    # --- the pnpm store ---------------------------------------------------
    #
    # A size report, like the mise rows, and never a path to delete. The apply
    # runs `pnpm store prune` once, which drops packages no project links and
    # keeps the rest. An rm -rf here broke every project's install at once.
    local pstore="${DISK_ROOT}/.local/share/pnpm/store"
    if [ -d "${pstore}" ]; then
      printf 'pstore\t%s\t%s\tpruned with pnpm store prune, never deleted\n' \
        "${pstore}" "$(du -sk "${pstore}" 2>/dev/null | cut -f1)" >>"${out}"
    fi

    disk_scan_playwright "${out}"
  fi
}

# --- Playwright browser revisions -------------------------------------------
#
# Under --caches, beside the caches, because a removed revision is a
# re-download too. Playwright installs each browser as
# ~/.cache/ms-playwright/<name>-<revision> and never removes an old one.
#
# A revision is kept when ANY playwright-core/browsers.json on the box names
# it. The box carries more than one playwright-core at once (the aube virtual
# store held 1.63, 1.64 and 1.65 on 2026-11-05), so the keep set is the union,
# not the pin of one copy. The match is on the revision number alone: the
# directory spells chromium-headless-shell as chromium_headless_shell, and a
# revision kept by mistake costs disk, not a broken browser.
#
# Kept directories get a `pwkeep` row so the report can show them; the apply
# ignores that type. With no browsers.json at all, nothing is offered for
# removal, because the scan cannot tell which revision is in use.
disk_scan_playwright() { # disk_scan_playwright <target file>
  local out="$1" pwdir="${DISK_ROOT}/.cache/ms-playwright" keep d base rev
  [ -d "${pwdir}" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    printf 'pwkeep\t%s\t0\tjq not on PATH, so no browsers.json can be read and no revision is offered for removal\n' \
      "${pwdir}" >>"${out}"
    return 0
  fi

  # `|| true` on the find: one of the two roots may not exist, and under
  # pipefail its non-zero exit would end the whole scan.
  keep="$({ find "${DISK_ROOT}/.cache/aube/virtual-store" \
    "${DISK_ROOT}/.local/share/mise/installs" \
    -path '*/playwright-core/browsers.json' -type f 2>/dev/null || true; } |
    while IFS= read -r d; do
      jq -r '.browsers[]?.revision // empty' "${d}" 2>/dev/null || true
    done | sort -u)"

  if [ -z "${keep}" ]; then
    printf 'pwkeep\t%s\t0\tno playwright-core/browsers.json under ~/.cache/aube/virtual-store or ~/.local/share/mise/installs, so no revision is offered for removal\n' \
      "${pwdir}" >>"${out}"
    return 0
  fi

  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    base="$(basename "${d}")"
    # <name>-<digits> only. `daemon`, cli-update-check.json and anything
    # else Playwright keeps here do not match and are left alone.
    case "${base}" in *?-*) ;; *) continue ;; esac
    rev="${base##*-}"
    case "${rev}" in '' | *[!0-9]*) continue ;; esac
    if printf '%s\n' "${keep}" | grep -qx "${rev}"; then
      printf 'pwkeep\t%s\t%s\tnamed by a playwright-core browsers.json\n' \
        "${d}" "$(du -sk "${d}" 2>/dev/null | cut -f1)" >>"${out}"
    else
      printf 'pw\t%s\t%s\trevision %s, named by no browsers.json\n' \
        "${d}" "$(du -sk "${d}" 2>/dev/null | cut -f1)" "${rev}" >>"${out}"
    fi
  done < <(find "${pwdir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

# --- node_modules in clean linked worktrees ---------------------------------
#
# The age rule above misses these: an agent or a review worktree installs,
# runs once, and leaves a fresh node_modules behind. A `wtnm` row qualifies
# whatever its age when the worktree passes disk_wtnm_reason: a clean tree,
# no commit missing from every remote (`--not --remotes` also covers a branch
# with no upstream), and no process with its cwd inside. No `git fetch` runs,
# so a squash-merged branch whose remote branch is gone fails the remote test
# and stays for gitkit's sweep. The main checkout never qualifies.

disk_wt_busy() { # disk_wt_busy <worktree>   0 when a process has its cwd in it
  local wt="${1%/}" c cwd
  for c in /proc/[0-9]*/cwd; do
    # Another user's process is unreadable. That is not a reason to stop.
    cwd="$(readlink "${c}" 2>/dev/null)" || continue
    case "${cwd}/" in "${wt}"/*) return 0 ;; esac
  done
  return 1
}

disk_wtnm_reason() { # disk_wtnm_reason <worktree>
  # Prints why the worktree's node_modules must stay, or nothing when it may go.
  # The scan and the apply both call this, because a commit can land between
  # the two.
  local wt="$1" st ahead
  if [ ! -f "${wt}/.git" ]; then
    echo "no longer a linked worktree"
  elif ! st="$(git -C "${wt}" status --porcelain 2>/dev/null)"; then
    echo "git status failed"
  elif [ -n "${st}" ]; then
    echo "uncommitted changes"
  elif ! ahead="$(git -C "${wt}" rev-list --count HEAD --not --remotes 2>/dev/null)"; then
    echo "git rev-list failed"
  elif [ "${ahead}" != "0" ]; then
    echo "${ahead} commit(s) on no remote"
  elif disk_wt_busy "${wt}"; then
    echo "a process has its cwd in the worktree"
  fi
}

disk_scan_wtnm() { # disk_scan_wtnm <target file> <repo>
  local out="$1" repo="$2" line wt='' wt_cur branch='' first=1 nm reason size_kb free_kb
  # --porcelain ends each record with a blank line. The first record is the
  # main checkout, which never qualifies. The trailing echo closes the last
  # record if a git version leaves its blank line off.
  while IFS= read -r line; do
    case "${line}" in
      'worktree '*) wt="${line#worktree }"; branch='(detached)' ;;
      'branch '*) branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
      '')
        [ -n "${wt}" ] || continue
        if [ "${first}" -eq 1 ]; then
          first=0
          wt=''
          continue
        fi
        nm="${wt}/node_modules"
        wt_cur="${wt}"
        wt=''
        # Scope is the home volume, like every other row.
        case "${nm}" in "${DISK_ROOT}"/*) ;; *) continue ;; esac
        [ -d "${nm}" ] && [ ! -L "${nm}" ] || continue
        # One path, one row: the age rule may already list it.
        if awk -F'\t' -v p="${nm}" '($1 == "nm" || $1 == "wtnm") && $2 == p { f = 1 } END { exit !f }' "${out}"; then
          continue
        fi
        reason="$(disk_wtnm_reason "${wt_cur}")"
        [ -z "${reason}" ] || continue
        read -r size_kb free_kb < <(disk_measure "${nm}")
        [ "${size_kb:-0}" -gt 0 ] || continue
        printf 'wtnm\t%s\t%s\tbranch: %s\t%s\n' \
          "${nm}" "${size_kb}" "${branch}" "${free_kb}" >>"${out}"
        ;;
    esac
  done < <(git -C "${repo}" worktree list --porcelain 2>/dev/null || true; echo)
}

# --- agent logs -------------------------------------------------------------
#
# Codex and Claude Code keep every session transcript forever, and T3 Code
# keeps its server logs. In scope, by mtime older than --logs <days>:
#
#   ~/.codex/sessions/**/*.jsonl             one row per file
#   ~/.claude/projects/<proj>/<uuid>.jsonl   one row, plus one row for the
#                                            <uuid>/ directory beside it
#   ~/.t3/userdata/logs/**                   one row per file
#
# The Claude walk stops at depth 2 and takes UUID-named files only, so
# <proj>/memory is never listed. disk_path_protected refuses it at apply too.
disk_scan_logs() { # disk_scan_logs <target file>
  local out="$1" days="${DISK_LOGS_DAYS}" kb f dir base
  local codex="${DISK_ROOT}/.codex/sessions"
  local claude="${DISK_ROOT}/.claude/projects"
  local t3="${DISK_ROOT}/.t3/userdata/logs"
  local uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

  if [ -d "${codex}" ]; then
    while IFS=$'\t' read -r kb f; do
      [ -n "${f}" ] || continue
      printf 'alog\t%s\t%s\tcodex sessions\n' "${f}" "${kb}" >>"${out}"
    done < <(find "${codex}" -xdev -type f -name '*.jsonl' -mtime "+${days}" \
      -printf '%k\t%p\n' 2>/dev/null | sort -t$'\t' -k2)
  fi

  if [ -d "${claude}" ]; then
    while IFS=$'\t' read -r kb f; do
      [ -n "${f}" ] || continue
      base="$(basename "${f}" .jsonl)"
      [[ "${base}" =~ ${uuid} ]] || continue
      printf 'alog\t%s\t%s\tclaude projects\n' "${f}" "${kb}" >>"${out}"
      dir="${f%.jsonl}"
      if [ -d "${dir}" ] && [ ! -L "${dir}" ]; then
        printf 'alog\t%s\t%s\tclaude projects\n' \
          "${dir}" "$(du -sk "${dir}" 2>/dev/null | cut -f1)" >>"${out}"
      fi
    done < <(find "${claude}" -xdev -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' \
      -mtime "+${days}" -printf '%k\t%p\n' 2>/dev/null | sort -t$'\t' -k2)
  fi

  if [ -d "${t3}" ]; then
    while IFS=$'\t' read -r kb f; do
      [ -n "${f}" ] || continue
      printf 'alog\t%s\t%s\tt3 logs\n' "${f}" "${kb}" >>"${out}"
    done < <(find "${t3}" -xdev -type f -mtime "+${days}" \
      -printf '%k\t%p\n' 2>/dev/null | sort -t$'\t' -k2)
  fi
}

# --- reading the scan back ------------------------------------------------

disk_sum_kb() { # disk_sum_kb <type> [file]
  awk -F'\t' -v t="$1" '$1 == t { s += $3 } END { print s + 0 }' "${2:-$(disk_targets)}" 2>/dev/null
}

# The least the delete of each row frees: FREE_KB where the row has one, else
# SIZE_KB. Only nm and wtnm rows carry FREE_KB, and a saved scan from before
# the column existed reads as it did then.
disk_sum_free_kb() { # disk_sum_free_kb <type> [file]
  awk -F'\t' -v t="$1" '$1 == t { s += ($5 ~ /^[0-9]+$/ ? $5 : $3) } END { print s + 0 }' \
    "${2:-$(disk_targets)}" 2>/dev/null
}

disk_count() { # disk_count <type> [file]
  awk -F'\t' -v t="$1" '$1 == t { n++ } END { print n + 0 }' "${2:-$(disk_targets)}" 2>/dev/null
}

# "3082 MiB on disk, at least 410 MiB freed" for one or more node_modules types.
disk_nm_sizes() { # disk_nm_sizes <type>...
  local t kb=0 free=0
  for t in "$@"; do
    kb=$((kb + $(disk_sum_kb "${t}")))
    free=$((free + $(disk_sum_free_kb "${t}")))
  done
  printf '%s MiB on disk, at least %s MiB freed' "$((kb / 1024))" "$((free / 1024))"
}

rows_disk() {
  emit_head 'reclaimable' "scanned at $(now_stamp), age window ${DISK_AGE_DAYS}d"
  emit_row '📦' 'node_modules' \
    "$(disk_count nm) tree(s), $(disk_nm_sizes nm)"
  emit_row '🌱' 'worktree node_modules' \
    "$(disk_count wtnm) tree(s), $(disk_nm_sizes wtnm) — clean, pushed, idle worktrees"
  emit_row '🔧' 'stale mise versions' \
    "$(disk_count mise) version(s), $(($(disk_sum_kb mise) / 1024)) MiB, mise prune"
  emit_row '📄' 'paseo logs' \
    "$(disk_count log) file(s), $(($(disk_sum_kb log) / 1024)) MiB"
  if [ -n "${DISK_LOGS_DAYS}" ]; then
    emit_row '📜' 'agent logs' \
      "$(disk_count alog) path(s), $(($(disk_sum_kb alog) / 1024)) MiB, older than ${DISK_LOGS_DAYS}d"
  else
    emit_row '📜' 'agent logs' "not scanned — devaloy disk --logs <days> includes them"
  fi
  if [ "${DISK_DO_CACHES}" -eq 1 ]; then
    emit_row '📚' 'caches' \
      "$(disk_count cache) dir(s), $(($(disk_sum_kb cache) / 1024)) MiB"
    emit_row '🧺' 'pnpm store' \
      "$(($(disk_sum_kb pstore) / 1024)) MiB — pnpm store prune, never deleted"
    emit_row '🎭' 'playwright' \
      "$(disk_count pw) old revision(s), $(($(disk_sum_kb pw) / 1024)) MiB, $(disk_count pwkeep) kept"
  else
    emit_row '📚' 'caches' "not scanned — devaloy disk --caches includes them"
    emit_row '🎭' 'playwright' "not scanned — devaloy disk --caches includes them"
  fi
  emit_row '🌿' 'git worktrees' \
    "$(disk_count wt) repo(s) with linked worktrees — listed, never deleted"
  emit_rule
  emit_row '💾' 'disk now' "$(status_disk_line)"
}

# --- the report -----------------------------------------------------------

disk_report() {
  local type path size_kb note free_kb

  echo "devaloy disk: disk before"
  df -h "${DISK_ROOT}" | tail -1
  echo

  echo "devaloy disk: node_modules untouched for ${DISK_AGE_DAYS}+ days"
  if [ "$(disk_count nm)" -eq 0 ]; then
    echo "  none"
  else
    while IFS=$'\t' read -r type path size_kb note free_kb; do
      [ "${type}" = "nm" ] || continue
      printf '  %6s MiB  %s\n' "$((size_kb / 1024))" "${path#"${DISK_ROOT}"/}"
      printf '               %s; at least %s MiB freed\n' \
        "${note}" "$((${free_kb:-${size_kb}} / 1024))"
    done <"$(disk_targets)"
    printf 'devaloy disk: %s tree(s), %s\n' "$(disk_count nm)" "$(disk_nm_sizes nm)"
  fi

  echo
  echo "devaloy disk: node_modules in clean, pushed, idle linked worktrees (any age)"
  if [ "$(disk_count wtnm)" -eq 0 ]; then
    echo "  none"
  else
    while IFS=$'\t' read -r type path size_kb note free_kb; do
      [ "${type}" = "wtnm" ] || continue
      printf '  %6s MiB  %s  (%s; at least %s MiB freed)\n' "$((size_kb / 1024))" \
        "$(dirname "${path#"${DISK_ROOT}"/}")" "${note}" "$((${free_kb:-${size_kb}} / 1024))"
    done <"$(disk_targets)"
    printf 'devaloy disk: %s tree(s), %s\n' "$(disk_count wtnm)" "$(disk_nm_sizes wtnm)"
  fi
  if [ "$(($(disk_count nm) + $(disk_count wtnm)))" -gt 0 ]; then
    echo "  (pnpm hard-links node_modules files from its store, so a delete frees"
    echo "   a file only when no other path links it)"
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
    done <"$(disk_targets)"
  fi
  echo "  (a linked worktree may hold uncommitted work — use gitkit's sweep to"
  echo "   remove merged ones, not this command)"

  echo
  echo "devaloy disk: stale mise tool versions (mise ls --prunable)"
  if [ "$(disk_count mise)" -eq 0 ]; then
    if ! command -v mise >/dev/null 2>&1; then
      echo "  mise not on PATH"
    elif ! command -v jq >/dev/null 2>&1; then
      echo "  jq not on PATH, so the prunable list is not read"
    else
      echo "  none"
    fi
  else
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "mise" ] || continue
      printf '  %6s MiB  %s\n' "$((size_kb / 1024))" "${note}"
    done <"$(disk_targets)"
    printf 'devaloy disk: %s version(s), %s MiB\n' \
      "$(disk_count mise)" "$(($(disk_sum_kb mise) / 1024))"
  fi

  if [ "$(disk_count log)" -gt 0 ]; then
    echo
    echo "devaloy disk: Paseo daemon logs older than ${DISK_AGE_DAYS} days"
    while IFS=$'\t' read -r type path size_kb note; do
      [ "${type}" = "log" ] || continue
      printf '  %6s KiB  %s\n' "${size_kb}" "$(basename "${path}")"
    done <"$(disk_targets)"
  fi

  echo
  # The row count is the second test because a saved scan (devaloy clean
  # --from) can carry agent log rows without --logs on this run.
  if [ -n "${DISK_LOGS_DAYS}" ] || [ "$(disk_count alog)" -gt 0 ]; then
    echo "devaloy disk: agent logs${DISK_LOGS_DAYS:+ older than ${DISK_LOGS_DAYS} days}"
    local group where n kb
    for group in 'codex sessions' 'claude projects' 't3 logs'; do
      case "${group}" in
        'codex sessions') where='~/.codex/sessions' ;;
        'claude projects') where='~/.claude/projects (session files and their directories)' ;;
        't3 logs') where='~/.t3/userdata/logs' ;;
      esac
      read -r n kb < <(awk -F'\t' -v g="${group}" \
        '$1 == "alog" && $4 == g { n++; s += $3 } END { print n + 0, s + 0 }' "$(disk_targets)")
      printf '  %5s path(s)  %6s MiB  %s\n' "${n}" "$((kb / 1024))" "${where}"
    done
    echo "  a deleted session can no longer be resumed"
  else
    echo "devaloy disk: agent logs: not scanned (--logs <days> includes them)"
  fi

  if [ "${DISK_DO_CACHES}" -eq 1 ] ||
    [ "$(($(disk_count cache) + $(disk_count pstore) + $(disk_count pw) + $(disk_count pwkeep)))" -gt 0 ]; then
    echo
    echo "devaloy disk: package manager caches"
    while IFS=$'\t' read -r type path size_kb note; do
      case "${type}" in
        cache) printf '  %6s MiB  %s\n' "$((size_kb / 1024))" "${path#"${DISK_ROOT}"/}" ;;
        pstore) printf '  %6s MiB  %s  (%s)\n' "$((size_kb / 1024))" "${path#"${DISK_ROOT}"/}" "${note}" ;;
      esac
    done <"$(disk_targets)"
    echo "  plus ~/.npm/_cacache, cleared with npm cache clean --force"

    echo
    echo "devaloy disk: Playwright browser revisions"
    if [ "$(disk_count pw)" -eq 0 ] && [ "$(disk_count pwkeep)" -eq 0 ]; then
      echo "  no ~/.cache/ms-playwright revisions"
    else
      while IFS=$'\t' read -r type path size_kb note; do
        case "${type}" in
          pw) printf '  %6s MiB  remove  %s  (%s)\n' "$((size_kb / 1024))" "$(basename "${path}")" "${note}" ;;
          pwkeep)
            # A row on ms-playwright itself is the scan saying why it listed
            # nothing, not a kept revision.
            if [ "${path}" = "${DISK_ROOT}/.cache/ms-playwright" ]; then
              echo "  ${note}"
            else
              printf '  %6s MiB  keep    %s  (%s)\n' "$((size_kb / 1024))" "$(basename "${path}")" "${note}"
            fi
            ;;
        esac
      done <"$(disk_targets)"
    fi
  else
    echo
    echo "devaloy disk: package manager caches and Playwright revisions: not scanned (--caches includes them)"
  fi
}

# --- the apply ------------------------------------------------------------
#
# Consumes the file the scan wrote, and touches nothing that is not in it. The
# exception is the `mise` type, whose row is a size report rather than a path:
# `mise prune` decides which versions to drop from its own tracked-configs, and
# an rm loop over those directories would be the thing that leaves the box
# without a toolchain.
#
# `pstore` works the same way: the row reports the pnpm store size, and the
# apply runs `pnpm store prune` once. Every path row passes disk_path_protected
# before its rm -rf, so a row under the never-delete list is refused, not run.
#
# <file> defaults to the disk scan's own. `devaloy clean --from` passes the rows
# of a saved scan it has already checked.
disk_apply_targets() { # disk_apply_targets [file]
  local file="${1:-$(disk_targets)}"
  local type path size_kb note free_kb removed_kb=0 removed_free_kb=0 removed=0 refused=0 skipped=0 did_pstore=0
  local reason tool avail_before avail_after
  local -a mise_tools=()

  # The scan's sizes are estimates, and the hard-link case can be far off. df
  # before and after gives the number that actually changed on the volume.
  avail_before="$(df -Pk "${DISK_ROOT}" 2>/dev/null | awk 'NR == 2 { print $4 }')"

  while IFS=$'\t' read -r type path size_kb note free_kb; do
    case "${type}" in
      nm | log | cache | pw | alog | wtnm)
        if disk_path_protected "${path}"; then
          echo "devaloy disk: refused, on the never-delete list: ${path}"
          refused=$((refused + 1))
          continue
        fi
        # The path may have gone since the scan. That is fine and expected: the
        # contract is that nothing OUTSIDE the list is touched, not that
        # everything in it still exists.
        [ -e "${path}" ] || continue
        # A worktree's node_modules qualified on its git state at scan time.
        # A commit, an edit or a shell in it since then keeps it.
        if [ "${type}" = "wtnm" ]; then
          reason="$(disk_wtnm_reason "$(dirname "${path}")")"
          if [ -n "${reason}" ]; then
            echo "devaloy disk: skipped ${path}: ${reason}"
            skipped=$((skipped + 1))
            continue
          fi
        fi
        act rm -rf "${path}"
        removed=$((removed + 1))
        removed_kb=$((removed_kb + size_kb))
        case "${free_kb}" in
          '' | *[!0-9]*) removed_free_kb=$((removed_free_kb + size_kb)) ;;
          *) removed_free_kb=$((removed_free_kb + free_kb)) ;;
        esac
        ;;
      wt)
        act git -C "${path}" worktree prune
        ;;
      mise)
        # NOTE is tool@version. The tool is everything before the last @, as
        # in npm:@antfu/ni@30.6.0. A saved scan can be edited by hand, so the
        # name must start with a letter or digit and never reads as an option.
        tool="${note%@*}"
        [[ "${tool}" =~ ^[A-Za-z0-9][A-Za-z0-9@:/._+-]*$ ]] || continue
        case " ${mise_tools[*]} " in *" ${tool} "*) ;; *) mise_tools+=("${tool}") ;; esac
        ;;
      pstore)
        # `pnpm store prune` rather than rm -rf: it drops packages no project
        # links and keeps the rest, so the projects you still work on reinstall
        # from the store instead of the network.
        [ "${did_pstore}" -eq 1 ] && continue
        did_pstore=1
        if ! command -v pnpm >/dev/null 2>&1; then
          echo "devaloy disk: pnpm not on PATH, store not pruned"
        elif [ "${APPLY}" -eq 1 ]; then
          echo "devaloy disk: pruning the pnpm store"
          pnpm store prune || true
        else
          echo "devaloy disk: would run: pnpm store prune"
        fi
        ;;
    esac
  done <"${file}"

  # One `mise prune` for the tools the rows named. It applies its own rule
  # again, so a version that stopped being prunable since the scan stays.
  if [ "${#mise_tools[@]}" -gt 0 ]; then
    if ! command -v mise >/dev/null 2>&1; then
      echo "devaloy disk: mise not on PATH, versions not pruned"
    elif [ "${APPLY}" -eq 1 ]; then
      echo "devaloy disk: pruning unused mise versions of ${mise_tools[*]}"
      mise prune "${mise_tools[@]}" || true
    else
      echo "devaloy disk: would run: mise prune ${mise_tools[*]}"
    fi
  fi

  # ~/.npm/_cacache. npm owns its layout, so npm clears it.
  if [ "${DISK_DO_CACHES}" -eq 1 ] && command -v npm >/dev/null 2>&1; then
    if [ "${APPLY}" -eq 1 ]; then
      npm cache clean --force >/dev/null 2>&1 || true
    else
      echo "devaloy disk: would run: npm cache clean --force"
    fi
  fi

  if [ "${APPLY}" -eq 1 ]; then
    printf 'devaloy disk: removed %s path(s), %s MiB on disk, at least %s MiB freed\n' \
      "${removed}" "$((removed_kb / 1024))" "$((removed_free_kb / 1024))"
    avail_after="$(df -Pk "${DISK_ROOT}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    if [ -n "${avail_before}" ] && [ -n "${avail_after}" ]; then
      printf 'devaloy disk: the volume gained %s MiB of free space (df, any other writer included)\n' \
        "$(((avail_after - avail_before) / 1024))"
    fi
  else
    printf 'devaloy disk: would remove %s path(s), %s MiB on disk, at least %s MiB freed\n' \
      "${removed}" "$((removed_kb / 1024))" "$((removed_free_kb / 1024))"
  fi
  if [ "${refused}" -gt 0 ]; then
    printf 'devaloy disk: refused %s path(s) on the never-delete list\n' "${refused}"
  fi
  if [ "${skipped}" -gt 0 ]; then
    printf 'devaloy disk: skipped %s worktree node_modules that failed the check again\n' "${skipped}"
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
  local mib free_mib t
  # pstore and pwkeep are size reports, not deletes, so they stay out of the sum.
  mib=0
  free_mib=0
  for t in nm wtnm log alog cache pw; do
    mib=$((mib + $(disk_sum_kb "${t}")))
    free_mib=$((free_mib + $(disk_sum_free_kb "${t}")))
  done
  mib=$((mib / 1024))
  free_mib=$((free_mib / 1024))
  if ! confirm \
    "devaloy disk will delete $(( $(disk_count nm) + $(disk_count wtnm) )) node_modules tree(s), $(disk_count log) Paseo log(s), $(disk_count alog) agent log path(s), $(disk_count pw) Playwright revision(s)," \
    "freeing ${free_mib} to ${mib} MiB$([ "$(disk_count mise)" -gt 0 ] && printf ', run mise prune')$([ "$(disk_count pstore)" -gt 0 ] && printf ', run pnpm store prune')." \
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
