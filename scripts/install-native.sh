#!/usr/bin/env bash
# Install devaloy natively on a fresh Ubuntu 24.04 VM, with no Docker, meant to
# be run via curl:
#
#   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-native.sh | sudo TS_AUTHKEY=tskey-auth-... bash
#
# For a branch or a tag, put the ref in both places:
#
#   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/<ref>/scripts/install-native.sh | sudo DEVALOY_REF=<ref> TS_AUTHKEY=tskey-auth-... bash
#
# It does at install time what the Dockerfile does at build time, then hands
# over to the same boot steps (lib/steps/) the container entrypoint calls, run
# by devaloy-boot.service on every boot. In order:
#
#    1. preflight: root, Ubuntu 24.04, x86_64 or aarch64, systemd, /dev/net/tun,
#       and a route to github.com and pkgs.tailscale.com
#    2. clone the repo to /opt/devaloy at DEVALOY_REF (default main), or fetch
#       and check out that ref when the clone is already there
#    3. merge the environment into /etc/devaloy/env (root, 0600); TS_AUTHKEY is
#       the one value it asks for, on /dev/tty, and only when it has none
#    4. apt: Tailscale's repo, config/apt/packages.txt, and the optional
#       browser libraries and Docker Engine
#    5. the dev user: next free UID, zsh, passwordless sudo
#    6. the devaloy CLI and lib/ to the paths the Dockerfile uses
#    7. /opt/devaloy/build-flags (RUNTIME=native)
#    8. tailscaled, then `tailscale up --ssh`
#    9. the systemd units: devaloy-boot, and devaloy-paseo / devaloy-t3code
#   10. run devaloy-boot and stream its log until the toolchain is ready
#   11. print how to connect
#
# Every step checks before it writes, so a second run with the same inputs
# changes no file under /etc, /opt/devaloy or /home/dev apart from the
# toolchain's own state and logs. A re-run is also how to change anything:
# set the variable, run the one-liner again.
#
# The clone comes before apt, unlike the plan's list, because the package
# lists live in the repo (config/apt/) and a curl-piped script has no repo
# beside it until it clones one.
set -euo pipefail

# Files this script writes must be readable by dev (the CLI, lib/, the units),
# and `sudo` may hand over a tighter umask than a login shell has.
umask 022

DEVALOY_DIR=/opt/devaloy
# The clone source. Only tests set it, to a local bare repo, because a branch
# under test is not on GitHub yet. It is used for the first clone, and on a
# re-run only when set, so a normal re-run never rewrites origin.
DEVALOY_SRC="${DEVALOY_SRC:-}"
DEVALOY_URL="https://github.com/mimukit/devaloy.git"
ENV_DIR=/etc/devaloy
ENV_FILE="${ENV_DIR}/env"
LIB_DIR=/usr/local/lib/devaloy
BIN_DIR=/usr/local/bin
UNIT_DIR=/etc/systemd/system
TS_SOCKET=/var/run/tailscale/tailscaled.sock

NO_WAIT=0
LOCKDOWN=0
CLI_ONLY=0

usage() {
  cat <<'EOF'
Usage: install-native.sh [--no-wait] [--lockdown]

  --no-wait    Return once Tailscale SSH is up. The toolchain bootstrap goes
               on in devaloy-boot.service; follow it with
               journalctl -fu devaloy-boot
  --lockdown   After Tailscale SSH is up, run scripts/host-firewall-lockdown.sh:
               ufw denies every inbound connection except on tailscale0. Refused
               from a public-IP SSH session, and when the session cannot be
               found, unless ALLOW_NON_TAILNET=1.
  --cli-only   Reinstall the devaloy CLI and lib/ from /opt/devaloy and stop.
               `devaloy update` runs this after its git pull.

Environment (a non-empty value overwrites the one in /etc/devaloy/env; an
empty or unset one keeps it):

  TS_AUTHKEY            Tailscale auth key (asked for when missing)
  TS_HOSTNAME           tailnet name, default devaloy
  DEVALOY_REF           branch or tag to install, default main
  WITH_DOCKER           true: Docker Engine from Docker's apt repo
  WITH_BROWSER          true: the headless Chromium libraries
  WITH_PASEO            true: the Paseo daemon (devaloy-paseo.service)
  WITH_T3CODE           true: the T3 Code server (devaloy-t3code.service)
  ALLOW_NON_TAILNET     1: let --lockdown run from a non-tailnet session

  and every variable in .env.example that applies to a VM: GITHUB_TOKEN,
  CLAUDE_CODE_OAUTH_TOKEN, CLOUDFLARE_API_TOKEN, DEVALOY_REPOS, GIT_AUTHOR_NAME,
  GIT_AUTHOR_EMAIL, GIT_SIGNING_SSH_KEY, NTFY_TOPIC, NTFY_SERVER, NTFY_TOKEN,
  WITH_PASEO_WEB_UI, PASEO_PASSWORD, PASEO_PLUGINS, TS_ACCEPT_DNS,
  MISE_NODE_VERSION, plus INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET.
EOF
}

ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()   { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# --- writing files only when they change -------------------------------------
#
# The whole idempotence contract rests on these two. A file is replaced only
# when its bytes or its mode differ, through a temp file in the same directory
# and a rename, so a reader never sees half a file and an unchanged file keeps
# its mtime. PUT_CHANGED tells the caller whether anything moved, which is
# what decides a daemon-reload or a docker restart.
PUT_CHANGED=0

put_file() { # put_file SRC DEST MODE
  local src="$1" dest="$2" mode="$3" tmp
  PUT_CHANGED=0
  if [ -f "${dest}" ] && [ ! -L "${dest}" ] && cmp -s "${src}" "${dest}" &&
     [ "$(stat -c %a "${dest}")" = "${mode#0}" ]; then
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  tmp="$(mktemp "${dest}.devaloy-XXXXXX")"
  cat "${src}" > "${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${dest}"
  PUT_CHANGED=1
}

# Feed it with `put_content DEST MODE < <(cmd)`, never `cmd | put_content`:
# the right side of a pipe runs in a subshell, and PUT_CHANGED would be set
# there and lost.
put_content() { # put_content DEST MODE, content on stdin
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  put_file "${tmp}" "$1" "$2"
  rm -f "${tmp}"
}

# --- apt -----------------------------------------------------------------------
#
# `apt-get update` runs only when a package is actually missing, and once per
# run unless a repo file changed since, so a re-run on a converged box makes no
# apt call at all. The lock timeout covers a cloud image whose
# unattended-upgrades is still running from first boot. NEEDRESTART_MODE=l
# makes Ubuntu's needrestart list the daemons an upgrade touched instead of
# restarting them: a restarted tailscaled would cut the Tailscale SSH session
# this script may be running in.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
APT_FRESH=0
APT=(apt-get -q -o DPkg::Lock::Timeout=600)

pkg_list() { # pkg_list FILE — the package names, comments and blanks stripped
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$1"
}

apt_ensure() { # apt_ensure PKG...
  local p missing=()
  for p in "$@"; do
    dpkg-query -W -f='${db:Status-Status}' "${p}" 2>/dev/null | grep -qx installed ||
      missing+=("${p}")
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  if [ "${APT_FRESH}" -eq 0 ]; then
    "${APT[@]}" update </dev/null
    APT_FRESH=1
  fi
  "${APT[@]}" install -y --no-install-recommends "${missing[@]}" </dev/null
  ok "installed: ${missing[*]}"
}

fetch_to() { # fetch_to URL DEST MODE — download, then put_file
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 3 "$1" -o "${tmp}"
  put_file "${tmp}" "$2" "$3"
  rm -f "${tmp}"
}

# --- /etc/devaloy/env ----------------------------------------------------------
#
# The VM's .env, and the EnvironmentFile= of every devaloy unit, so it has to
# parse the way systemd parses it. Every value is written in double quotes,
# with the four characters systemd unescapes inside them (\ " ` $) escaped.
# Inside double quotes systemd keeps every other byte, a newline included, so
# any value survives the trip.
#
# It is read back with read_env_file, a parser of the same grammar, and never
# with `source`: a token can hold a `$` or a backtick, and a shell would
# expand them. The keys are the .env.example names that mean something on a
# VM (the compose-only DEVALOY_RUNTIME, DEVALOY_PRIVILEGED and the resource
# ceilings do not), plus TS_HOSTNAME, DEVALOY_REF and RUNTIME. INFISICAL_* are
# not in .env.example but the steps read them, so they are here too. A key
# someone added by hand is kept, after these, in the order it had.
ENV_KEYS=(
  TS_AUTHKEY TS_HOSTNAME TS_ACCEPT_DNS
  GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLOUDFLARE_API_TOKEN
  INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET
  DEVALOY_REPOS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_SIGNING_SSH_KEY
  NTFY_TOPIC NTFY_SERVER NTFY_TOKEN
  WITH_DOCKER WITH_BROWSER WITH_PASEO WITH_PASEO_WEB_UI WITH_T3CODE
  PASEO_PASSWORD PASEO_PLUGINS MISE_NODE_VERSION
  DEVALOY_REF RUNTIME
)

declare -A FILE_VAL=()
FILE_ORDER=()
declare -A VAL=()

env_default() { # env_default KEY — the value a key takes when no one set it
  case "$1" in
    TS_HOSTNAME) printf 'devaloy' ;;
    DEVALOY_REF) printf 'main' ;;
    RUNTIME) printf 'native' ;;
    WITH_DOCKER|WITH_BROWSER|WITH_PASEO|WITH_T3CODE) printf 'false' ;;
    *) printf '' ;;
  esac
}

# read_env_file FILE — fill FILE_VAL and FILE_ORDER from a systemd environment
# file. The grammar is systemd's (src/basic/env-file.c): `#` and `;` start a
# comment line; KEY=VALUE, whitespace around the `=` dropped; a double-quoted
# value unescapes \" \\ \` \$, keeps any other backslash pair as it is, drops a
# backslash-newline and keeps a bare newline; a single-quoted value is literal;
# an unquoted value ends at the newline, a backslash takes the next byte
# literally, and trailing blanks go. A line without `=` is skipped, as systemd
# skips it.
read_env_file() {
  local LC_ALL=C
  local data n i c c2 key val
  FILE_VAL=()
  FILE_ORDER=()
  [ -f "$1" ] || return 0
  data="$(cat "$1"; printf x)"
  data="${data%x}"
  n=${#data}
  i=0
  while [ "${i}" -lt "${n}" ]; do
    c="${data:i:1}"
    case "${c}" in
      ' '|$'\t'|$'\n'|$'\r') i=$((i + 1)); continue ;;
      '#'|';')
        while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != $'\n' ]; do i=$((i + 1)); done
        continue
        ;;
    esac
    key=""
    while [ "${i}" -lt "${n}" ]; do
      c="${data:i:1}"
      [ "${c}" = "=" ] || [ "${c}" = $'\n' ] && break
      key+="${c}"
      i=$((i + 1))
    done
    key="${key%"${key##*[![:space:]]}"}"
    if [ "${c}" != "=" ]; then
      continue
    fi
    i=$((i + 1))
    while [ "${i}" -lt "${n}" ] && { [ "${data:i:1}" = ' ' ] || [ "${data:i:1}" = $'\t' ]; }; do
      i=$((i + 1))
    done
    val=""
    c="${data:i:1}"
    if [ "${c}" = '"' ]; then
      i=$((i + 1))
      while [ "${i}" -lt "${n}" ]; do
        c="${data:i:1}"
        if [ "${c}" = '"' ]; then
          i=$((i + 1))
          break
        elif [ "${c}" = "\\" ]; then
          c2="${data:i+1:1}"
          case "${c2}" in
            '"'|"\\"|'`'|'$') val+="${c2}" ;;
            $'\n') ;;
            *) val+="\\${c2}" ;;
          esac
          i=$((i + 2))
        else
          val+="${c}"
          i=$((i + 1))
        fi
      done
    elif [ "${c}" = "'" ]; then
      i=$((i + 1))
      while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != "'" ]; do
        val+="${data:i:1}"
        i=$((i + 1))
      done
      i=$((i + 1))
    else
      while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != $'\n' ]; do
        c="${data:i:1}"
        if [ "${c}" = "\\" ]; then
          c2="${data:i+1:1}"
          [ "${c2}" = $'\n' ] || val+="${c2}"
          i=$((i + 2))
        else
          val+="${c}"
          i=$((i + 1))
        fi
      done
      val="${val%"${val##*[![:space:]]}"}"
    fi
    # Anything after a closing quote up to the newline is dropped.
    while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != $'\n' ]; do i=$((i + 1)); done
    case "${key}" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;;
    esac
    [ -n "${FILE_VAL[${key}]+set}" ] || FILE_ORDER+=("${key}")
    FILE_VAL[${key}]="${val}"
  done
}

env_quote() { # env_quote VALUE — the double-quoted form systemd reads back
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\`/\\\`}"
  v="${v//\$/\\\$}"
  printf '"%s"' "${v}"
}

is_env_key() {
  local k
  for k in "${ENV_KEYS[@]}"; do [ "${k}" = "$1" ] && return 0; done
  return 1
}

# resolve_env — the precedence from the plan: a non-empty environment variable
# wins, then the file, then the default. RUNTIME is not an input; it is native
# because this script is running.
resolve_env() {
  local k envv
  read_env_file "${ENV_FILE}"
  for k in "${ENV_KEYS[@]}"; do
    envv="${!k:-}"
    if [ "${k}" = RUNTIME ]; then
      VAL[${k}]=native
    elif [ -n "${envv}" ]; then
      VAL[${k}]="${envv}"
    elif [ -n "${FILE_VAL[${k}]:-}" ]; then
      VAL[${k}]="${FILE_VAL[${k}]}"
    else
      VAL[${k}]="$(env_default "${k}")"
    fi
  done
  for k in WITH_DOCKER WITH_BROWSER WITH_PASEO WITH_T3CODE; do
    case "${VAL[${k}]}" in
      true|false) ;;
      *) die "${k}=${VAL[${k}]} — use true or false." ;;
    esac
  done
}

render_env() {
  local k
  cat <<'EOF'
# devaloy's environment on this VM: the native counterpart of the container's
# .env, read by devaloy-boot, devaloy-paseo and devaloy-t3code through
# EnvironmentFile=. Written by scripts/install-native.sh. Root only (0600).
#
# Edit a value, then run `sudo systemctl restart devaloy-boot` (and
# devaloy-paseo or devaloy-t3code if you changed theirs). Clearing a token here
# and restarting revokes it. A non-empty variable passed to the installer
# overwrites the value here; an empty one leaves it.
#
# Keep the double quotes. Inside them, write \\ \" \` and \$ for a literal
# backslash, quote, backtick and dollar sign.
EOF
  for k in "${ENV_KEYS[@]}"; do
    printf '%s=%s\n' "${k}" "$(env_quote "${VAL[${k}]}")"
  done
  for k in "${FILE_ORDER[@]}"; do
    is_env_key "${k}" && continue
    printf '%s=%s\n' "${k}" "$(env_quote "${FILE_VAL[${k}]}")"
  done
}

# --- the free 10.x range probe -------------------------------------------------
#
# A copy of the CIDR helpers in scripts/setup-sysbox-host.sh, its twin. That
# script runs from curl on a host with no repo, so it cannot source a shared
# file, and this one runs before the clone's lib/ is installed. Change one,
# change the other. IN_USE is filled by docker_in_use below rather than from
# `docker network ls`, because on this VM Docker is not the outer host.
IN_USE=()
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}
cidr_bounds() { # "10.0.0.1/16" -> "start end", both as integers
  local ip="${1%/*}" bits="${1#*/}" base mask start size
  base=$(ip2int "$ip")
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  start=$(( base & mask ))
  size=$(( bits >= 32 ? 1 : (1 << (32 - bits)) ))
  echo "$start $(( start + size - 1 ))"
}
cidr_overlaps() { # two CIDRs -> exit 0 when they share any address
  local a_lo a_hi b_lo b_hi
  read -r a_lo a_hi <<<"$(cidr_bounds "$1")"
  read -r b_lo b_hi <<<"$(cidr_bounds "$2")"
  [ "$a_lo" -le "$b_hi" ] && [ "$b_lo" -le "$a_hi" ]
}
overlaps_any() { # CIDR vs the IN_USE list
  local sub
  for sub in "${IN_USE[@]:-}"; do
    [ -z "$sub" ] && continue
    case "$sub" in *:*) continue ;; esac   # IPv6, not our arithmetic
    cidr_overlaps "$1" "$sub" && return 0
  done
  return 1
}

# Every IPv4 route (all tables, so Tailscale's table 52 counts) and every
# interface address on the VM, minus Docker's own bridges. Leaving those out is
# what keeps a re-run stable: once dockerd runs, docker0 sits on the bip this
# script chose, and counting it would push the next run onto another range.
docker_in_use() {
  IN_USE=()
  local sub
  while read -r sub; do
    [ -n "${sub}" ] && IN_USE+=("${sub}")
  done < <(
    ip -4 route show table all 2>/dev/null | awk '
      {
        i = 1
        if ($1 ~ /^(local|broadcast|unreachable|prohibit|blackhole|throw|multicast|anycast|unicast|nat)$/) i = 2
        d = $i
        if (d == "default") next
        dev = ""
        for (j = 1; j <= NF; j++) if ($j == "dev") dev = $(j + 1)
        if (dev == "lo" || dev == "docker0" || dev ~ /^br-/ || dev ~ /^veth/) next
        if (d !~ /\//) d = d "/32"
        print d
      }'
    ip -4 -o addr show 2>/dev/null |
      awk '$2 != "lo" && $2 != "docker0" && $2 !~ /^br-/ && $2 !~ /^veth/ {print $4}'
  )
}

# --- the SSH session behind sudo -----------------------------------------------
#
# host-firewall-lockdown.sh refuses to run from a public-IP SSH session by
# reading SSH_CONNECTION. Under `sudo` that guard is blind: sudo's env_reset
# drops SSH_CONNECTION, the script sees an empty source, and a session on the
# public IP locks itself out. The variable is still in the environment of the
# processes above this one (the login shell, and sudo itself, which keeps the
# environment it was started with), and root can read /proc/<pid>/environ. So
# walk the parent chain and take the first one. Prints nothing when no
# ancestor has it: a provider console, or a session started some other way.
ssh_connection_of_session() {
  local pid="$$" ppid v
  if [ -n "${SSH_CONNECTION:-}" ]; then
    printf '%s' "${SSH_CONNECTION}"
    return 0
  fi
  while [ -n "${pid}" ] && [ "${pid}" -gt 1 ]; do
    v="$(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -1)"
    if [ -n "${v}" ]; then
      printf '%s' "${v}"
      return 0
    fi
    # The fourth field of /proc/<pid>/stat, counted after the `)` that closes
    # the command name, which may itself hold spaces.
    ppid="$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $2}')"
    [ -n "${ppid}" ] && [ "${ppid}" != "${pid}" ] || break
    pid="${ppid}"
  done
  return 0
}

# ===============================================================================
# The steps
# ===============================================================================

inst_preflight() {
  head_ "1. Preflight"
  [ "$(id -u)" -eq 0 ] || die "Run as root: curl -fsSL ... | sudo bash"

  local id="" version=""
  if [ -r /etc/os-release ]; then
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
  fi
  [ "${id}" = "ubuntu" ] && [ "${version}" = "24.04" ] ||
    die "This installer supports Ubuntu 24.04 only (found ${id:-unknown} ${version:-unknown})."
  ok "Ubuntu ${version}"

  case "$(uname -m)" in
    x86_64|aarch64) ok "architecture $(uname -m)" ;;
    *) die "Unsupported architecture $(uname -m). devaloy runs on x86_64 and aarch64." ;;
  esac

  # Everything after step 8 is a systemd unit, and a box without systemd as
  # PID 1 (a container, WSL without systemd) would fail there, after apt and
  # the user. Fail here instead.
  [ -d /run/systemd/system ] ||
    die "systemd is not running as PID 1 here. The native install needs it; in a container, use docker compose instead."
  ok "systemd"

  if [ ! -c /dev/net/tun ]; then
    modprobe tun 2>/dev/null || true
  fi
  [ -c /dev/net/tun ] ||
    die "/dev/net/tun is missing and 'modprobe tun' did not create it. Tailscale needs it; enable TUN in the VM's settings."
  ok "/dev/net/tun"

  local host
  for host in github.com pkgs.tailscale.com; do
    timeout 10 bash -c "exec 3<>/dev/tcp/${host}/443" 2>/dev/null ||
      die "Cannot reach ${host}:443. Check DNS and outbound HTTPS."
  done
  ok "github.com and pkgs.tailscale.com reachable"
}

# Branch or tag, decided by asking the remote. ls-remote writes nothing, so a
# re-run on a clone that is already at the remote's commit makes no write in
# /opt/devaloy at all; a fetch only happens when the remote moved.
inst_clone() {
  head_ "2. The repo at ${DEVALOY_DIR}"
  apt_ensure git ca-certificates curl

  local ref="${VAL[DEVALOY_REF]}" remote_sha tag_sha local_sha branch
  if [ ! -d "${DEVALOY_DIR}/.git" ]; then
    if [ -e "${DEVALOY_DIR}" ] && [ -n "$(ls -A "${DEVALOY_DIR}" 2>/dev/null)" ]; then
      die "${DEVALOY_DIR} exists and is not a git clone. Move it aside and re-run."
    fi
    git clone --quiet "${DEVALOY_SRC:-${DEVALOY_URL}}" "${DEVALOY_DIR}" </dev/null
    ok "cloned ${DEVALOY_SRC:-${DEVALOY_URL}}"
  elif [ -n "${DEVALOY_SRC}" ] &&
       [ "$(git -C "${DEVALOY_DIR}" remote get-url origin)" != "${DEVALOY_SRC}" ]; then
    git -C "${DEVALOY_DIR}" remote set-url origin "${DEVALOY_SRC}"
  fi

  local g=(git -C "${DEVALOY_DIR}")
  remote_sha="$("${g[@]}" ls-remote --heads origin "refs/heads/${ref}" </dev/null |
    awk -v r="refs/heads/${ref}" '$2 == r {print $1}')"
  if [ -n "${remote_sha}" ]; then
    # A branch: end on a local branch that tracks origin, so `devaloy update`
    # can `git pull --ff-only` later.
    if [ "$("${g[@]}" rev-parse -q --verify "refs/remotes/origin/${ref}" || true)" != "${remote_sha}" ]; then
      "${g[@]}" fetch --quiet origin "+refs/heads/${ref}:refs/remotes/origin/${ref}" </dev/null
    fi
    branch="$("${g[@]}" symbolic-ref -q --short HEAD || true)"
    local_sha="$("${g[@]}" rev-parse HEAD)"
    if [ "${branch}" != "${ref}" ] || [ "${local_sha}" != "${remote_sha}" ] ||
       [ "$("${g[@]}" config "branch.${ref}.merge" || true)" != "refs/heads/${ref}" ]; then
      "${g[@]}" checkout --quiet -B "${ref}" --track "origin/${ref}" </dev/null
      ok "checked out branch ${ref} at $("${g[@]}" rev-parse --short HEAD)"
    else
      ok "branch ${ref} already at $("${g[@]}" rev-parse --short HEAD)"
    fi
  else
    # An annotated tag lists twice: the tag object, and the commit it points
    # at as <tag>^{}. Take the commit when there is one.
    tag_sha="$("${g[@]}" ls-remote --tags origin "refs/tags/${ref}" </dev/null |
      awk -v r="refs/tags/${ref}" '$2 == r "^{}" {p = $1} $2 == r {t = $1} END {print (p != "" ? p : t)}')"
    [ -n "${tag_sha}" ] || die "DEVALOY_REF=${ref} is neither a branch nor a tag on origin."
    if [ "$("${g[@]}" rev-parse -q --verify "refs/tags/${ref}^{commit}" || true)" != "${tag_sha}" ]; then
      "${g[@]}" fetch --quiet --force origin "+refs/tags/${ref}:refs/tags/${ref}" </dev/null
    fi
    if "${g[@]}" symbolic-ref -q HEAD >/dev/null || [ "$("${g[@]}" rev-parse HEAD)" != "${tag_sha}" ]; then
      "${g[@]}" checkout --quiet --detach "refs/tags/${ref}" </dev/null
      ok "checked out tag ${ref} (detached; devaloy update will not pull a tag)"
    else
      ok "tag ${ref} already checked out"
    fi
  fi

  # The two flag files live in the clone's root, where the container keeps
  # them too. Excluded locally so `git pull` never sees them as changes.
  local exclude="${DEVALOY_DIR}/.git/info/exclude" line
  for line in /build-flags /runtime-flags '/runtime-flags.devaloy-new'; do
    grep -qxF "${line}" "${exclude}" 2>/dev/null || {
      mkdir -p "$(dirname "${exclude}")"
      printf '%s\n' "${line}" >> "${exclude}"
    }
  done
}

# The prompt is the one interactive moment, and it reads /dev/tty because stdin
# is the script itself under `curl | bash`. A node that is already logged in
# needs no key (someone recovered it by hand with `tailscale up`), so it is
# not asked for then.
inst_secrets() {
  head_ "3. /etc/devaloy/env"
  if [ -z "${VAL[TS_AUTHKEY]}" ] &&
     ! { command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; }; then
    if ( exec </dev/tty ) 2>/dev/null; then
      printf '  Tailscale auth key (tskey-auth-...): ' >/dev/tty
      IFS= read -r -s 'VAL[TS_AUTHKEY]' </dev/tty || true
      printf '\n' >/dev/tty
    fi
    if [ -z "${VAL[TS_AUTHKEY]}" ]; then
      local cmd="curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/${VAL[DEVALOY_REF]}/scripts/install-native.sh | sudo"
      [ "${VAL[DEVALOY_REF]}" = main ] || cmd="${cmd} DEVALOY_REF=${VAL[DEVALOY_REF]}"
      cmd="${cmd} TS_AUTHKEY=tskey-auth-..."
      [ "${VAL[TS_HOSTNAME]}" = devaloy ] || cmd="${cmd} TS_HOSTNAME=${VAL[TS_HOSTNAME]}"
      local k
      for k in WITH_DOCKER WITH_BROWSER WITH_PASEO WITH_T3CODE; do
        [ "${VAL[${k}]}" = true ] && cmd="${cmd} ${k}=true"
      done
      cmd="${cmd} bash"
      local flags=""
      [ "${NO_WAIT}" -eq 1 ] && flags="${flags} --no-wait"
      [ "${LOCKDOWN}" -eq 1 ] && flags="${flags} --lockdown"
      [ -z "${flags}" ] || cmd="${cmd} -s --${flags}"
      die "TS_AUTHKEY is not set, it is not in ${ENV_FILE}, and there is no terminal to ask on.
Re-run with the key:

  ${cmd}"
    fi
  fi

  [ -d "${ENV_DIR}" ] || install -d -m 0755 "${ENV_DIR}"
  put_content "${ENV_FILE}" 600 < <(render_env)
  if [ "${PUT_CHANGED}" -eq 1 ]; then
    ok "written (root, 0600)"
  else
    ok "unchanged"
  fi
}

inst_apt() {
  head_ "4. Packages"
  # Tailscale's repo for noble, the same two files the Dockerfile's fetch
  # stage downloads and the ones Tailscale's own install script writes.
  fetch_to https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
    /usr/share/keyrings/tailscale-archive-keyring.gpg 644
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0
  fetch_to https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
    /etc/apt/sources.list.d/tailscale.list 644
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0

  local pkgs
  mapfile -t pkgs < <(pkg_list "${DEVALOY_DIR}/config/apt/packages.txt")
  [ "${#pkgs[@]}" -gt 0 ] || die "config/apt/packages.txt is empty or missing."
  apt_ensure "${pkgs[@]}"

  # Ubuntu ships bat as batcat and fd as fdfind; the Dockerfile links the
  # short names in /usr/bin, and so does this.
  [ -e /usr/bin/bat ] || ln -s /usr/bin/batcat /usr/bin/bat
  [ -e /usr/bin/fd ] || ln -s /usr/bin/fdfind /usr/bin/fd
  ok "base packages present ($(printf '%s' "${#pkgs[@]}") listed)"

  if [ "${VAL[WITH_BROWSER]}" = true ]; then
    mapfile -t pkgs < <(pkg_list "${DEVALOY_DIR}/config/apt/browser.txt")
    apt_ensure "${pkgs[@]}"
    ok "browser libraries present (the bootstrap fetches playwright-cli and Chromium)"
  fi

  if [ "${VAL[WITH_DOCKER]}" = true ]; then
    feature_docker
  fi
}

# WITH_DOCKER=true. Docker Engine from Docker's own apt repo, as the
# Dockerfile's WITH_DOCKER block installs it, but as the VM's own daemon: no
# Sysbox, no nesting. daemon.json and the OOM drop-in go in BEFORE the
# packages, so the daemon the package starts on install already runs with
# them, and a first install needs no restart.
feature_docker() {
  head_ "4b. Docker Engine"
  fetch_to https://download.docker.com/linux/ubuntu/gpg /usr/share/keyrings/docker.asc 644
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0
  put_content /etc/apt/sources.list.d/docker.list 644 < <(
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' \
      "$(dpkg --print-architecture)")
  [ "${PUT_CHANGED}" -eq 0 ] || APT_FRESH=0

  # The address ranges. config/docker/daemon.json pins the bridge to
  # 10.201.0.1/16 and the pool to 10.202.0.0/16; keep both when nothing on
  # this VM overlaps them, otherwise take the first free 10.x/16 pair from the
  # same candidates scripts/setup-sysbox-host.sh tries.
  local repo_json="${DEVALOY_DIR}/config/docker/daemon.json" bip base n
  bip="$(jq -r '.bip' "${repo_json}")"
  base="$(jq -r '.["default-address-pools"][0].base' "${repo_json}")"
  docker_in_use
  if overlaps_any "${bip}" || overlaps_any "${base}"; then
    warn "the repo's ranges (${bip}, ${base}) overlap this VM's network, picking others"
    bip=""
    for n in 210 220 230 240 250; do
      if ! overlaps_any "10.${n}.0.1/16"; then bip="10.${n}.0.1/16"; break; fi
    done
    [ -n "${bip}" ] || die "Could not find a free 10.x/16 for the Docker bridge."
    base=""
    for n in 211 221 231 241 251; do
      if [ "10.${n}.0.0/16" != "${bip%.*.*}.0.0/16" ] && ! overlaps_any "10.${n}.0.0/16"; then
        base="10.${n}.0.0/16"; break
      fi
    done
    [ -n "${base}" ] || die "Could not find a free 10.x/16 for the Docker address pool."
  fi
  local docker_was_active=0
  systemctl is-active --quiet docker 2>/dev/null && docker_was_active=1
  # Into a variable first: a jq failure then stops the script under set -e,
  # where a process substitution would hand put_content an empty file.
  local json
  json="$(jq --arg bip "${bip}" --arg base "${base}" \
    '.bip = $bip | .["default-address-pools"][0].base = $base' "${repo_json}")"
  put_content /etc/docker/daemon.json 644 <<<"${json}"
  local daemon_changed="${PUT_CHANGED}"
  ok "daemon.json: bip ${bip}, pool ${base}"

  put_file "${DEVALOY_DIR}/config/systemd/docker.service.d/devaloy-oom.conf" \
    "${UNIT_DIR}/docker.service.d/devaloy-oom.conf" 644
  [ "${PUT_CHANGED}" -eq 0 ] || systemctl daemon-reload

  apt_ensure docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  set_oom docker -250

  if [ "${daemon_changed}" -eq 1 ] && [ "${docker_was_active}" -eq 1 ]; then
    systemctl restart docker
    ok "docker restarted for the new daemon.json"
  fi
}

# OOMScoreAdjust= applies when a unit starts. Writing the value into the
# running daemon as well puts it in force now, without the restart that would
# cut every session through tailscaled or bounce every container.
set_oom() { # set_oom UNIT VALUE
  local pid
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null || true)"
  [ -n "${pid}" ] && [ "${pid}" != 0 ] || return 0
  [ "$(cat "/proc/${pid}/oom_score_adj" 2>/dev/null)" = "$2" ] && return 0
  echo "$2" > "/proc/${pid}/oom_score_adj" 2>/dev/null || true
}

inst_user() {
  head_ "5. The dev user"
  if id dev >/dev/null 2>&1; then
    ok "dev exists (uid $(id -u dev))"
  else
    # No fixed UID: the cloud image's ubuntu user usually holds 1000, and it
    # stays as the provider console's way in. useradd takes the next free one.
    if getent group dev >/dev/null 2>&1; then
      useradd --create-home --home-dir /home/dev --shell /usr/bin/zsh --gid dev dev
    else
      useradd --create-home --home-dir /home/dev --shell /usr/bin/zsh --user-group dev
    fi
    ok "created dev (uid $(id -u dev))"
  fi

  local tmp
  tmp="$(mktemp)"
  echo 'dev ALL=(ALL) NOPASSWD:ALL' > "${tmp}"
  visudo -cqf "${tmp}" || die "visudo rejected the dev sudoers drop-in."
  put_file "${tmp}" /etc/sudoers.d/dev 440
  rm -f "${tmp}"
  ok "passwordless sudo"

  if [ "${VAL[WITH_DOCKER]}" = true ] && ! id -nG dev | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker dev
    ok "dev added to the docker group"
  fi
}

# The paths the Dockerfile COPYs to: the three scripts in /usr/local/bin, lib/
# in /usr/local/lib/devaloy, and the five old verb names as symlinks. A file in
# /usr/local/lib/devaloy that the repo no longer has is removed, which a fresh
# image gets for free.
install_cli() {
  local f rel mode
  for f in devaloy bootstrap-toolchain.sh link-shims; do
    put_file "${DEVALOY_DIR}/${f}" "${BIN_DIR}/${f}" 755
  done
  while IFS= read -r f; do
    rel="${f#"${DEVALOY_DIR}/lib/"}"
    mode=644
    [ -x "${f}" ] && mode=755
    put_file "${f}" "${LIB_DIR}/${rel}" "${mode}"
  done < <(find "${DEVALOY_DIR}/lib" -type f | sort)
  while IFS= read -r f; do
    rel="${f#"${LIB_DIR}/"}"
    [ -e "${DEVALOY_DIR}/lib/${rel}" ] || rm -f "${f}"
  done < <(find "${LIB_DIR}" -type f)
  for f in devaloy-update devaloy-disk devaloy-ram devaloy-prune devaloy-nvim-sync; do
    [ "$(readlink "${BIN_DIR}/${f}" 2>/dev/null)" = "${BIN_DIR}/devaloy" ] ||
      ln -sfn "${BIN_DIR}/devaloy" "${BIN_DIR}/${f}"
  done
}

inst_cli() {
  head_ "6. The devaloy CLI"
  install_cli
  ok "devaloy, bootstrap-toolchain.sh, link-shims, ${LIB_DIR}"
}

inst_build_flags() {
  head_ "7. build-flags"
  put_content "${DEVALOY_DIR}/build-flags" 644 < <(
    printf 'WITH_DOCKER=%s\nWITH_BROWSER=%s\nRUNTIME=native\n' \
      "${VAL[WITH_DOCKER]}" "${VAL[WITH_BROWSER]}")
  ok "WITH_DOCKER=${VAL[WITH_DOCKER]} WITH_BROWSER=${VAL[WITH_BROWSER]} RUNTIME=native"
}

# The values the steps read, exported for the step functions sourced below.
export_step_env() {
  export RUNTIME=native
  export TS_HOSTNAME="${VAL[TS_HOSTNAME]}"
  export TS_AUTHKEY="${VAL[TS_AUTHKEY]}"
  export TS_ACCEPT_DNS="${VAL[TS_ACCEPT_DNS]}"
  [ -n "${TS_ACCEPT_DNS}" ] || unset TS_ACCEPT_DNS
}

inst_tailscale() {
  head_ "8. Tailscale SSH"
  put_file "${DEVALOY_DIR}/config/systemd/tailscaled.service.d/devaloy-oom.conf" \
    "${UNIT_DIR}/tailscaled.service.d/devaloy-oom.conf" 644
  [ "${PUT_CHANGED}" -eq 0 ] || systemctl daemon-reload
  systemctl is-enabled --quiet tailscaled 2>/dev/null || systemctl enable tailscaled
  systemctl is-active --quiet tailscaled 2>/dev/null || systemctl start tailscaled
  set_oom tailscaled -500

  for _ in $(seq 1 30); do
    [ -S "${TS_SOCKET}" ] && break
    sleep 1
  done

  # The same function devaloy-boot calls on every boot, which calls the same
  # step_tailscale_up the container calls. Sourced from the installed lib/.
  export_step_env
  # shellcheck source=lib/steps/common.sh
  . "${LIB_DIR}/steps/common.sh"
  # shellcheck source=lib/steps/tailscale.sh
  . "${LIB_DIR}/steps/tailscale.sh"
  step_tailscale_ensure

  if ! ts_is_up_as "${VAL[TS_HOSTNAME]}"; then
    # sshd is untouched and --lockdown has not run, so the session this runs
    # in, or the provider console, is still the way in.
    die "tailscale up failed, so this VM is not on the tailnet. sshd and the
firewall are untouched, so public SSH still works. Fix the key or the ACL,
then either re-run this installer, or run:

  sudo tailscale up --ssh --hostname=${VAL[TS_HOSTNAME]}"
  fi
}

# The units. All three unit files are installed whatever the flags say, so
# `devaloy doctor` finds them and a flag turned on later only enables one.
inst_units() {
  head_ "9. systemd units"
  local changed=0 u
  UNIT_CHANGED=()
  for u in devaloy-boot devaloy-paseo devaloy-t3code; do
    put_file "${DEVALOY_DIR}/config/systemd/${u}.service" "${UNIT_DIR}/${u}.service" 644
    if [ "${PUT_CHANGED}" -eq 1 ]; then
      changed=1
      UNIT_CHANGED+=("${u}")
    fi
  done
  [ "${changed}" -eq 0 ] || systemctl daemon-reload
  systemctl is-enabled --quiet devaloy-boot 2>/dev/null || systemctl enable --quiet devaloy-boot
  ok "devaloy-boot enabled"

  feature_unit devaloy-paseo "${VAL[WITH_PASEO]}"
  feature_unit devaloy-t3code "${VAL[WITH_T3CODE]}"
}

# A flag on enables the unit; inst_start starts it after the boot. A flag off
# disables and stops it, so turning WITH_PASEO back to false and re-running
# takes the daemon down.
FEATURE_START=()
feature_unit() { # feature_unit UNIT true|false
  if [ "$2" = true ]; then
    systemctl is-enabled --quiet "$1" 2>/dev/null || systemctl enable --quiet "$1"
    FEATURE_START+=("$1")
    ok "$1 enabled"
  else
    if systemctl is-enabled --quiet "$1" 2>/dev/null || systemctl is-active --quiet "$1" 2>/dev/null; then
      systemctl disable --now --quiet "$1"
      ok "$1 disabled and stopped"
    fi
  fi
}

# restart, not start: on a box where devaloy-boot already ran, start would be a
# no-op for a RemainAfterExit oneshot, and a re-run must run the boot steps
# again (that is how a changed /etc/devaloy/env reaches ~/.devaloy_secrets).
# A feature unit is restarted only when its unit file changed, because a
# restart ends every agent session the server holds.
inst_start() {
  head_ "10. devaloy-boot"
  local u action
  if [ "${NO_WAIT}" -eq 1 ]; then
    systemctl restart --no-block devaloy-boot
    ok "started in the background"
  else
    echo "  streaming 'journalctl -u devaloy-boot' until the boot steps finish."
    echo "  A cold toolchain install takes several minutes."
    echo
    # The follower is a background job, so a Ctrl-C or a die must not leave
    # it running after the script; the trap covers both. A Ctrl-C only stops
    # the wait: systemd keeps the boot job going.
    journalctl -f -o cat -n 0 -u devaloy-boot &
    JOURNAL_PID=$!
    trap 'kill "${JOURNAL_PID}" 2>/dev/null || true' EXIT
    local rc=0
    systemctl restart devaloy-boot || rc=$?
    # One second for journald to hand over the last lines before the stop.
    sleep 1
    kill "${JOURNAL_PID}" 2>/dev/null || true
    wait "${JOURNAL_PID}" 2>/dev/null || true
    trap - EXIT
    [ "${rc}" -eq 0 ] || die "devaloy-boot failed. Read 'journalctl -u devaloy-boot -b' for the step
that broke. Tailscale SSH is up, so you can log in as dev to fix it, then run
'sudo systemctl restart devaloy-boot'."
    ok "devaloy-boot finished"
  fi
  # --no-block in both modes: with --no-wait the start queues behind the boot
  # job (the units order After=devaloy-boot), and otherwise it returns at once.
  for u in "${FEATURE_START[@]}"; do
    action=start
    case " ${UNIT_CHANGED[*]} " in *" ${u} "*) action=restart ;; esac
    systemctl "${action}" --no-block "${u}"
  done
}

# --lockdown. Only reached when step 8 proved the node is on the tailnet. The
# lockdown script's own guards stay as they are; this hands it the
# SSH_CONNECTION that sudo stripped (see ssh_connection_of_session).
inst_lockdown() {
  head_ "Lockdown"
  tailscale ip -4 >/dev/null 2>&1 || die "tailscale ip -4 does not answer; refusing --lockdown."
  apt_ensure ufw

  if ufw status verbose 2>/dev/null | grep -q '^Status: active' &&
     ufw status verbose 2>/dev/null | grep -q 'deny (incoming)' &&
     ufw status verbose 2>/dev/null | grep -Eq 'on tailscale0 +ALLOW IN'; then
    ok "already locked down: incoming denied except on tailscale0"
    return 0
  fi

  local conn
  conn="$(ssh_connection_of_session)"
  if [ -z "${conn}" ] && [ "${ALLOW_NON_TAILNET:-}" != 1 ]; then
    die "Refusing --lockdown: this installer could not find the SSH session it
runs in, so it cannot tell whether the firewall would cut you off. Run it
from an SSH session over Tailscale (ssh dev@${VAL[TS_HOSTNAME]}), or from the
provider console with ALLOW_NON_TAILNET=1."
  fi
  [ -z "${conn}" ] || ok "SSH session from ${conn%% *}"
  SSH_CONNECTION="${conn}" ALLOW_NON_TAILNET="${ALLOW_NON_TAILNET:-}" \
    "${DEVALOY_DIR}/scripts/host-firewall-lockdown.sh" </dev/null ||
    die "host-firewall-lockdown.sh refused (see above). The install itself is complete."
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-wait) NO_WAIT=1 ;;
      --lockdown) LOCKDOWN=1 ;;
      --cli-only) CLI_ONLY=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done

  if [ "${CLI_ONLY}" -eq 1 ]; then
    [ "$(id -u)" -eq 0 ] || die "--cli-only needs root: sudo $0 --cli-only"
    [ -f "${DEVALOY_DIR}/devaloy" ] || die "${DEVALOY_DIR} holds no clone to install from."
    install_cli
    echo "devaloy: cli reinstalled from ${DEVALOY_DIR}"
    exit 0
  fi

  inst_preflight
  resolve_env
  inst_clone
  inst_secrets
  inst_apt
  inst_user
  inst_cli
  inst_build_flags
  inst_tailscale
  inst_units
  inst_start
  [ "${LOCKDOWN}" -eq 0 ] || inst_lockdown

  head_ "11. Done"
  if [ "${NO_WAIT}" -eq 1 ]; then
    echo "  The toolchain bootstrap goes on in devaloy-boot.service. Follow it with:"
    echo "    journalctl -fu devaloy-boot"
  fi
  echo "devaloy is up. Connect with: ssh dev@${VAL[TS_HOSTNAME]}"
}

# Tests source this file for its functions (the env-file parser, the SSH
# session lookup) without running an install.
if [ "${DEVALOY_INSTALL_LIB_ONLY:-0}" != 1 ]; then
  # main is called on the last line on purpose. Under `curl | bash`, bash
  # reads the script from stdin as it goes; by the time main runs, bash has
  # read every function above it, so a command inside that reads stdin cannot
  # swallow the rest of the script.
  main "$@"
fi
