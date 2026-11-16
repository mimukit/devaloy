#!/usr/bin/env bash
# devaloy boot steps: the development database forward (DEVALOY_DB_UPSTREAM).
#
# Sourced by entrypoint.sh after common.sh, never executed. The restart loop
# stays in entrypoint.sh, like the other long-running processes.
#
# Every project on every box reads its development database at one address,
# 127.0.0.1:${DEVALOY_DB_PORT} (5435 unless set). The project's DATABASE_URL
# in Infisical then holds the same value on every box, and no project carries a
# setting for one machine. What differs per box is where that address leads,
# and that is this one key in the box's own .env:
#
#   DEVALOY_DB_UPSTREAM=100.120.15.77:5435    the Dokploy Postgres on the host
#
# The container has its own network namespace, so its 127.0.0.1 is not the
# host's, and a Postgres that Dokploy deploys on the host is not there. socat
# listens on the container's loopback and opens one connection to the upstream
# for each client. Postgres speaks plain TCP, so nothing in between needs to
# understand it, and TLS, when the upstream asks for it, passes through.
#
# A native VM has no such gap: a Postgres the host publishes on 127.0.0.1 is
# already where the projects look. The native boot does not run this step.

# The upstream is quoted into a command `su -c` runs, so only a plain
# host:port passes: a name or an IPv4 address, a colon, and digits.
DB_FORWARD_UPSTREAM_RE='^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$'

# db_forward_valid <upstream> — true for a plain host:port with a usable port.
db_forward_valid() {
  local port
  [[ "$1" =~ ${DB_FORWARD_UPSTREAM_RE} ]] || return 1
  port="${1##*:}"
  [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

# Sets DB_FORWARD_READY=1 when the forward can start, and DB_FORWARD_PORT. A
# bad value warns and leaves the forward off; the box itself still starts.
step_db_forward_config() {
  DB_FORWARD_READY=0
  DB_FORWARD_PORT="${DEVALOY_DB_PORT:-5435}"
  if ! db_forward_valid "${DEVALOY_DB_UPSTREAM}"; then
    log "WARNING: DEVALOY_DB_UPSTREAM='${DEVALOY_DB_UPSTREAM}' is not host:port."
    log "WARNING: not starting the database forward. Fix the key in .env."
    return 0
  fi
  if ! db_forward_valid "127.0.0.1:${DB_FORWARD_PORT}"; then
    log "WARNING: DEVALOY_DB_PORT='${DB_FORWARD_PORT}' is not a port number."
    log "WARNING: not starting the database forward. Fix the key in .env."
    return 0
  fi
  if ! command -v socat >/dev/null 2>&1; then
    log "WARNING: DEVALOY_DB_UPSTREAM is set, but socat is not in this image."
    log "WARNING: rebuild it: docker compose up -d --build"
    return 0
  fi
  # shellcheck disable=SC2034  # read by entrypoint.sh, not by this file.
  DB_FORWARD_READY=1
}
