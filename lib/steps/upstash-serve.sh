#!/usr/bin/env bash
# devaloy on an Upstash Box: start, stop or restart the two background
# processes the box keeps, the T3 Code server and the userspace tailscaled.
#
#   upstash-serve.sh t3 [start]        the T3 Code serve loop, detached
#   upstash-serve.sh t3 stop           stop the loop and the server under it
#   upstash-serve.sh t3 restart        stop, then start (devaloy update)
#   upstash-serve.sh tailscaled [start|stop|restart]
#
# The Upstash twin of native-serve.sh. A box has no systemd, and pause kills
# every process, so the boot (upstash-boot.sh) calls this on every container
# start. Each process runs in a restart loop, the twin of the container's
# loops in entrypoint.sh: `while :; do <server>; sleep 10; done`, under
# `setsid nohup`, so it outlives the boot and the SSH session that ran it.
#
# A second start does nothing when the loop already runs or the port already
# has a listener. The loop writes its own PID to a file under
# /workspace/.devaloy/run, and the check reads /proc for that PID and its
# command line. `pgrep -f` is not used: in the hand setup it matched the SSH
# command line that ran the check, and reported a server that was not there.
# A pidfile left by a pause or a reset names a dead PID, or a PID some other
# process took, and the command line check tells those apart.
#
# t3 runs as the box user; tailscaled runs as root. Run as root, this script
# drops to the box user for t3 by itself.
set -euo pipefail

# The same umask as upstash-boot.sh, for the same reason: this script also
# starts from `devaloy update` and from a hand-run shell, and a loose umask
# there left the pidfile at 666.
umask 022

DEV_USER="${DEV_USER:-boxuser}"
UPSTASH_DIR="${UPSTASH_DIR:-/workspace/.devaloy}"
RUN_DIR="${UPSTASH_DIR}/run"
LOG_DIR="${UPSTASH_DIR}/logs"
TS_STATE_DIR="${TS_STATE_DIR:-${UPSTASH_DIR}/tailscale}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
T3CODE_PORT=3773
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

log() { echo "[devaloy] $*"; }

# The home comes from the passwd entry, not from DEV_HOME, so the server runs
# with the home that `su -l` and Upstash SSH give the user. The boot sets it to
# /workspace/home, or leaves /home/boxuser in the Home fallback.
dev_home() { getent passwd "${DEV_USER}" | cut -d: -f6; }

# loop_pid NAME — the PID of a running loop, or nothing. The PID must be alive
# and its command line must be this script's loop for NAME.
loop_pid() {
  local pid cmd
  pid="$(cat "${RUN_DIR}/$1.pid" 2>/dev/null || true)"
  case "${pid}" in ''|*[!0-9]*) return 0 ;; esac
  # The braces put the redirect of the open itself under 2>/dev/null: a
  # stale pid after a pause otherwise prints "No such file" into the log.
  cmd="$( { tr '\0' ' ' < "/proc/${pid}/cmdline"; } 2>/dev/null || true)"
  case "${cmd}" in
    *"upstash-serve.sh $1 loop"*) printf '%s' "${pid}" ;;
  esac
}

# listening PORT — true when some process listens on the TCP port.
listening() {
  [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]
}

# --- T3 Code -------------------------------------------------------------------

# The `su -l` environment of native-serve.sh, for the reason given there: the
# server and every agent it spawns get HOME, USER, LOGNAME, SHELL and the
# default PATH, plus what ~/.devaloy_secrets exports, and nothing else. PATH is
# Debian's login PATH: the mise shims are not on it, and the server finds
# `claude`, `codex` and `t3` through the /usr/local/bin mirror that link-shims
# keeps. SHELL is zsh because the server opens its terminals from $SHELL.
#
# The bind is 0.0.0.0, not a tailnet address as on a VM: the Upstash preview
# proxy reaches the server on the container address, and the T3 pairing token
# is the lock. T3CODE_TELEMETRY_ENABLED=false and
# T3CODE_SERVER_BROWSER_SANDBOX=0 are the container's two variables, for the
# reasons given at its loop in entrypoint.sh.
t3_loop() {
  local home
  home="$(dev_home)"
  printf '%s\n' "$$" > "${RUN_DIR}/t3.pid"
  local login_env=(
    env -i
    HOME="${home}"
    USER="${DEV_USER}"
    LOGNAME="${DEV_USER}"
    MAIL="/var/mail/${DEV_USER}"
    SHELL=/usr/bin/zsh
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
  )
  [ -n "${LANG:-}" ] && login_env+=(LANG="${LANG}")
  # The `if [ -f ]` guard is load-bearing for the dash reason given at the
  # Paseo loop in entrypoint.sh.
  local secrets_line="if [ -f '${home}/.devaloy_secrets' ]; then . '${home}/.devaloy_secrets'; fi;"
  cd "${home}"
  while :; do
    log "starting the T3 Code server on 0.0.0.0:${T3CODE_PORT}"
    "${login_env[@]}" /bin/sh -c "export T3CODE_TELEMETRY_ENABLED=false T3CODE_SERVER_BROWSER_SANDBOX=0; \
      ${secrets_line} exec t3 serve --host 0.0.0.0 --port '${T3CODE_PORT}' --no-browser" || true
    log "WARNING: the T3 Code server exited, restarting in 10s"
    sleep 10
  done
}

t3_start() {
  local pid
  pid="$(loop_pid t3)"
  if [ -n "${pid}" ]; then
    log "T3 Code: the serve loop already runs (pid ${pid})"
    return 0
  fi
  if listening "${T3CODE_PORT}"; then
    log "T3 Code: something already listens on :${T3CODE_PORT}, so no second server"
    return 0
  fi
  if [ ! -x /usr/local/bin/t3 ]; then
    log "WARNING: t3 is not installed, so the T3 Code server cannot start. The"
    log "WARNING: toolchain bootstrap did not finish; read the boot log."
    return 1
  fi
  setsid nohup bash "${SELF}" t3 loop >> "${LOG_DIR}/t3.log" 2>&1 < /dev/null &
  log "T3 Code: serve loop started, log in ${LOG_DIR}/t3.log"
}

# --- tailscaled ----------------------------------------------------------------

# Userspace networking, because the box has no /dev/net/tun. Tailscale SSH
# still works in this mode: tailscaled terminates the connection and spawns
# the shell itself. The state lives on /workspace, so the node keeps its
# identity through a reset and rejoins with no key.
tailscaled_loop() {
  printf '%s\n' "$$" > "${RUN_DIR}/tailscaled.pid"
  mkdir -p "${TS_STATE_DIR}" "$(dirname "${TS_SOCKET}")"
  chmod 700 "${TS_STATE_DIR}"
  while :; do
    log "starting tailscaled (userspace networking)"
    tailscaled --tun=userspace-networking \
      --state="${TS_STATE_DIR}/tailscaled.state" \
      --statedir="${TS_STATE_DIR}" \
      --socket="${TS_SOCKET}" || true
    log "WARNING: tailscaled exited, restarting in 10s"
    sleep 10
  done
}

tailscaled_start() {
  local pid
  pid="$(loop_pid tailscaled)"
  if [ -n "${pid}" ]; then
    log "tailscaled already runs (loop pid ${pid})"
  elif [ -S "${TS_SOCKET}" ] && tailscale --socket="${TS_SOCKET}" status >/dev/null 2>&1; then
    log "tailscaled already answers on ${TS_SOCKET}"
  else
    setsid nohup bash "${SELF}" tailscaled loop >> "${LOG_DIR}/tailscaled.log" 2>&1 < /dev/null &
    log "tailscaled started, log in ${LOG_DIR}/tailscaled.log"
  fi
  for _ in $(seq 1 30); do
    [ -S "${TS_SOCKET}" ] && return 0
    sleep 1
  done
  log "WARNING: the tailscaled socket never appeared; read ${LOG_DIR}/tailscaled.log."
  return 1
}

# --- stop ------------------------------------------------------------------------

# The loop is a session leader (setsid), so its PID is the process group of
# the loop, the shell under it and the server. One signal to the group stops
# all of them; the wait is bounded, then the group gets SIGKILL.
loop_stop() { # loop_stop NAME [PORT]
  local pid
  pid="$(loop_pid "$1")"
  if [ -z "${pid}" ]; then
    log "$1: no loop runs"
    rm -f "${RUN_DIR}/$1.pid"
    return 0
  fi
  kill -TERM -- "-${pid}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    [ -d "/proc/${pid}" ] || break
    sleep 0.5
  done
  [ ! -d "/proc/${pid}" ] || kill -KILL -- "-${pid}" 2>/dev/null || true
  if [ -n "${2:-}" ]; then
    for _ in $(seq 1 20); do
      listening "$2" || break
      sleep 0.5
    done
  fi
  rm -f "${RUN_DIR}/$1.pid"
  log "$1: stopped (loop pid ${pid})"
}

# --- dispatch ----------------------------------------------------------------

what="${1:-}"
action="${2:-start}"

case "${what}" in
  t3)
    # The server runs as the box user. Root hands the call over, with the
    # two directories made first, so the user can write its pidfile and log.
    if [ "$(id -u)" -eq 0 ]; then
      install -d -o "${DEV_USER}" -g "${DEV_USER}" "${UPSTASH_DIR}" "${RUN_DIR}" "${LOG_DIR}"
      exec runuser -u "${DEV_USER}" -- env DEV_USER="${DEV_USER}" UPSTASH_DIR="${UPSTASH_DIR}" \
        LANG="${LANG:-}" bash "${SELF}" "$@"
    fi
    mkdir -p "${RUN_DIR}" "${LOG_DIR}"
    case "${action}" in
      start) t3_start ;;
      stop) loop_stop t3 "${T3CODE_PORT}" ;;
      restart) loop_stop t3 "${T3CODE_PORT}"; t3_start ;;
      loop) t3_loop ;;
      *) echo "upstash-serve.sh: unknown action '${action}' for t3" >&2; exit 2 ;;
    esac
    ;;
  tailscaled)
    [ "$(id -u)" -eq 0 ] || exec sudo -n bash "${SELF}" "$@"
    mkdir -p "${RUN_DIR}" "${LOG_DIR}"
    case "${action}" in
      start) tailscaled_start ;;
      stop) loop_stop tailscaled ;;
      restart) loop_stop tailscaled; tailscaled_start ;;
      loop) tailscaled_loop ;;
      *) echo "upstash-serve.sh: unknown action '${action}' for tailscaled" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "upstash-serve.sh: expected t3 or tailscaled, got '${what}'" >&2
    exit 2
    ;;
esac
