#!/usr/bin/env bash
# devaloy fleet: run the devaloy verbs on every devaloy box on the tailnet.
#
#   devaloy fleet [list]            each box: online state, runtime, clone state
#   devaloy fleet status            `devaloy status` on every online box
#   devaloy fleet doctor            `devaloy doctor` on every online box
#   devaloy fleet update [box...]   gate, `devaloy update`, `devaloy health`,
#                                   one box at a time, this box last
#
# THE LIST IS THE TAILNET. There is no inventory file, because this repo is
# public and a committed list would carry addresses. A box is a Tailscale node
# whose MagicDNS name starts with `devaloy-` and whose OS is linux. The name is
# the first label of DNSName, not HostName: in a container HostName is the
# container's own name (`devaloy`), and only DNSName carries `devaloy-ovh`.
# The OS check keeps a laptop with a devaloy- name out of the list.
#
# A BOX IS REACHED BY ADDRESS, read from the same status JSON on every run and
# never stored. Inside the container the Docker resolver does not answer
# MagicDNS names, so `ssh devaloy-insta` fails where `ssh dev@<ip>` works.
# Tailscale SSH does the auth, so there is no key to manage.
#
# THE FAR BOX NEEDS NO NEW CLI. Only verbs every box already has (status,
# doctor, update, health) and plain git run there, so a box on an older image
# still answers.
#
# THE UPDATE GATE. In a container `devaloy update` installs the CLI and config
# from ~/projects/devaloy, so that clone is the release. Before each box the
# gate requires a clean `main` that is not ahead of origin/main, then
# fast-forwards it. Any other state stops the run before that box, so no box
# installs a feature branch, uncommitted edits, or commits that exist nowhere
# else. A box with no clone updates from the image copy in /opt/devaloy.
#
# DEVALOY_FLEET_STATUS_JSON=<file> reads a saved `tailscale status --json`
# instead of asking tailscaled, for a test with fixture boxes.
# DEVALOY_FLEET_CLONE=<dir> moves the clone the gate checks on THIS box only;
# the far box always checks its own ~/projects/devaloy.

FLEET_PREFIX='devaloy-'
FLEET_TIMEOUT="${DEVALOY_FLEET_TIMEOUT:-1800}"
FLEET_SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# The remote halves are plain strings, because the far box runs them through
# its own login shell over SSH. Keep them POSIX sh: dev's shell is zsh.
# shellcheck disable=SC2016
FLEET_PROBE='r=$(sed -n "s/^RUNTIME=//p" /opt/devaloy/build-flags 2>/dev/null | head -1)
[ "$r" = native ] || r=container
c="${DEVALOY_FLEET_CLONE:-$HOME/projects/devaloy}"
if git -C "$c" rev-parse --git-dir >/dev/null 2>&1; then
  b=$(git -C "$c" symbolic-ref --short -q HEAD || echo detached)
  h=$(git -C "$c" rev-parse --short HEAD)
  d=""
  [ -z "$(git -C "$c" status --porcelain)" ] || d="*"
  printf "%s\t%s %s%s\n" "$r" "$b" "$h" "$d"
else
  printf "%s\tno clone\n" "$r"
fi'

# shellcheck disable=SC2016
FLEET_GATE='c="${DEVALOY_FLEET_CLONE:-$HOME/projects/devaloy}"
if ! git -C "$c" rev-parse --git-dir >/dev/null 2>&1; then
  echo "gate: no clone at $c, so the update uses /opt/devaloy"
  exit 0
fi
b=$(git -C "$c" symbolic-ref --short -q HEAD)
if [ "$b" != main ]; then
  echo "gate: the clone is on ${b:-a detached HEAD}, not main. Switch it to main first."
  exit 1
fi
d=$(git -C "$c" status --porcelain)
if [ -n "$d" ]; then
  echo "gate: the clone has uncommitted changes. Commit or remove them first:"
  printf "%s\n" "$d"
  exit 1
fi
if ! git -C "$c" fetch --quiet origin main; then
  echo "gate: git fetch origin main failed"
  exit 1
fi
a=$(git -C "$c" rev-list --count origin/main..main)
if [ "$a" -ne 0 ]; then
  echo "gate: main is $a commit(s) ahead of origin/main. Run git push first:"
  git -C "$c" log --oneline origin/main..main
  exit 1
fi
if ! git -C "$c" merge --ff-only --quiet origin/main; then
  echo "gate: the fast-forward to origin/main failed"
  exit 1
fi
echo "gate: main is at $(git -C "$c" rev-parse --short HEAD), same as origin/main"'

fleet_status_json() {
  if [ -n "${DEVALOY_FLEET_STATUS_JSON:-}" ]; then
    cat "${DEVALOY_FLEET_STATUS_JSON}"
    return
  fi
  timeout 10 tailscale status --json 2>/dev/null ||
    die "fleet: 'tailscale status --json' failed. Is tailscaled up?"
}

# fleet_boxes: one TSV row per box, sorted by name: name, ip, online|offline,
# self|-. The self node is always online: this code runs on it.
fleet_boxes() {
  fleet_status_json | jq -r --arg p "${FLEET_PREFIX}" '
    [ (.Self + {IsSelf: true, Online: true}),
      ((.Peer // {}) | .[] | . + {IsSelf: false}) ]
    | map(select(.OS == "linux")
          | . + {Name: ((.DNSName // "") | split(".")[0])}
          | select(.Name | startswith($p)))
    | sort_by(.Name)
    | .[]
    | [ .Name,
        ((.TailscaleIPs // [])[0] // "-"),
        (if .Online then "online" else "offline" end),
        (if .IsSelf then "self" else "-" end) ]
    | @tsv'
}

# fleet_run <ip> <self|-> <command>: run one command string on a box. The local
# box runs it under bash with no SSH.
fleet_run() {
  if [ "$2" = "self" ]; then
    timeout "${FLEET_TIMEOUT}" bash -c "$3"
  else
    timeout "${FLEET_TIMEOUT}" ssh "${FLEET_SSH_OPTS[@]}" "dev@$1" "$3"
  fi
}

fleet_prefix() { # fleet_prefix <name>: prefix every line of stdin
  sed -u "s/^/$1: /"
}

fleet_list() {
  local tmp name ip state self rows=0
  tmp="$(mktemp -d)"
  while IFS=$'\t' read -r name ip state self; do
    rows=$((rows + 1))
    [ "${state}" = "online" ] || continue
    fleet_run "${ip}" "${self}" "${FLEET_PROBE}" >"${tmp}/${name}" 2>/dev/null &
  done < <(fleet_boxes)
  wait
  if [ "${rows}" -eq 0 ]; then
    rm -rf "${tmp}"
    die "fleet: no tailnet node has a name that starts with ${FLEET_PREFIX}"
  fi

  printf '%-24s %-8s %-10s %s\n' BOX STATE RUNTIME CLONE
  while IFS=$'\t' read -r name ip state self; do
    local runtime='-' clone='-' label="${name}"
    [ "${self}" = "self" ] && label="${name} (self)"
    if [ "${state}" = "online" ]; then
      if [ -s "${tmp}/${name}" ]; then
        IFS=$'\t' read -r runtime clone <"${tmp}/${name}"
      else
        runtime='?' clone='unreachable'
      fi
    fi
    printf '%-24s %-8s %-10s %s\n' "${label}" "${state}" "${runtime}" "${clone}"
  done < <(fleet_boxes)
  rm -rf "${tmp}"
}

# fleet_each <verb>: run `devaloy <verb>` on every online box in parallel.
# Each box's output is buffered and printed as one block, in name order, so
# lines from two boxes never mix.
fleet_each() {
  local verb="$1" tmp name ip state self rc failed=0
  tmp="$(mktemp -d)"
  while IFS=$'\t' read -r name ip state self; do
    [ "${state}" = "online" ] || continue
    # `&& rc=0 || rc=$?` keeps the exit code: devaloy runs under set -e, which
    # would end this job at a failed SSH before the code is written.
    { fleet_run "${ip}" "${self}" "devaloy ${verb}" >"${tmp}/${name}.out" 2>&1 && rc=0 || rc=$?
      echo "${rc}" >"${tmp}/${name}.rc"; } &
  done < <(fleet_boxes)
  wait

  local summary=()
  while IFS=$'\t' read -r name ip state self; do
    if [ "${state}" != "online" ]; then
      summary+=("${name}: skipped (offline)")
      continue
    fi
    fleet_prefix "${name}" <"${tmp}/${name}.out"
    echo
    rc="$(cat "${tmp}/${name}.rc")"
    if [ "${rc}" -eq 0 ]; then
      summary+=("${name}: ok")
    else
      summary+=("${name}: failed (exit ${rc})")
      failed=$((failed + 1))
    fi
  done < <(fleet_boxes)
  rm -rf "${tmp}"

  printf '%s\n' "fleet ${verb}:" "${summary[@]/#/  }"
  [ "${failed}" -eq 0 ]
}

# fleet_step <name> <ip> <self> <label> <command>: run one update step with the
# output streamed and prefixed. Returns the step's exit code.
fleet_step() {
  local name="$1" ip="$2" self="$3" label="$4" cmd="$5" rc
  printf '%s: --- %s\n' "${name}" "${label}"
  # pipefail makes the pipeline's code the far command's, since sed exits 0.
  fleet_run "${ip}" "${self}" "${cmd}" 2>&1 | fleet_prefix "${name}" && rc=0 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf 'fleet update: stopped at %s, step "%s" (exit %s)\n' "${name}" "${label}" "${rc}" >&2
  fi
  return "${rc}"
}

fleet_update() {
  local name ip state self arg found
  local boxes=() remote=() local_box=''
  local row

  mapfile -t boxes < <(fleet_boxes)
  [ "${#boxes[@]}" -gt 0 ] ||
    die "fleet: no tailnet node has a name that starts with ${FLEET_PREFIX}"

  # A named box must be one fleet knows, and online. Refuse before any box
  # changes, so a typo in the second name cannot leave the first one updated.
  for arg in "$@"; do
    found=''
    for row in "${boxes[@]}"; do
      IFS=$'\t' read -r name ip state self <<<"${row}"
      [ "${name}" = "${arg}" ] && found="${state}"
    done
    [ -n "${found}" ] || die "fleet update: ${arg} is not a ${FLEET_PREFIX}* box on the tailnet. See 'devaloy fleet list'."
    [ "${found}" = "online" ] || die "fleet update: ${arg} is offline."
  done

  for row in "${boxes[@]}"; do
    IFS=$'\t' read -r name ip state self <<<"${row}"
    if [ "$#" -gt 0 ]; then
      found=''
      for arg in "$@"; do [ "${arg}" = "${name}" ] && found=1; done
      [ -n "${found}" ] || continue
    fi
    if [ "${state}" != "online" ]; then
      echo "fleet update: ${name} skipped (offline)"
      continue
    fi
    if [ "${self}" = "self" ]; then
      local_box="${row}"
    else
      remote+=("${row}")
    fi
  done
  # The local box goes last: its update can replace the CLI and the agent that
  # runs this, so every far box is done before that happens.
  [ -n "${local_box}" ] && remote+=("${local_box}")

  for row in "${remote[@]}"; do
    IFS=$'\t' read -r name ip state self <<<"${row}"
    fleet_step "${name}" "${ip}" "${self}" "clone gate" "${FLEET_GATE}" || return 1
    fleet_step "${name}" "${ip}" "${self}" "devaloy update" "devaloy update" || return 1
    fleet_step "${name}" "${ip}" "${self}" "devaloy health" "devaloy health" || return 1
    printf '%s: updated, health ok\n' "${name}"
  done
  echo "fleet update: ${#remote[@]} box(es) updated"
}

do_fleet() {
  require jq ssh
  local sub="${1:-list}"
  [ "$#" -gt 0 ] && shift
  case "${sub}" in
    list)
      [ "$#" -eq 0 ] || die "fleet list: takes no arguments"
      fleet_list
      ;;
    status | doctor)
      [ "$#" -eq 0 ] || die "fleet ${sub}: takes no arguments"
      fleet_each "${sub}"
      ;;
    update) fleet_update "$@" ;;
    *)
      printf 'devaloy: fleet: unknown command: %s\n' "${sub}" >&2
      printf 'usage: devaloy fleet [list|status|doctor|update [box...]]\n' >&2
      exit 2
      ;;
  esac
}
