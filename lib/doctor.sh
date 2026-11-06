#!/usr/bin/env bash
# devaloy: what this box was built with, and what is broken.
#
# THE EXIT CODE IS THE POINT. An agent or a hook calling this needs to tell
# "you did not build Docker" from "dockerd died", and those are the same
# observation — `docker info` fails — with opposite meanings. So this reads
# /opt/devaloy/build-flags first and judges the probe against it:
#
#   built in + working   ok, exit 0
#   built in + failing   BROKEN, exit 1
#   not built in         off, exit 0. Not a fault. A minimal box is correct.
#
# That is the distinction CLAUDE.md keeps making in prose ("say so rather than
# trying to install Docker"), written down once where a script can branch on it.
#
# WITH_PASEO, WITH_T3CODE and the runtime half of WITH_DOCKER are not in the
# flags file on purpose. They are runtime variables that `docker compose up -d`
# can flip without a rebuild, so an image-baked answer would be wrong; they come
# from the runtime flags file entrypoint.sh writes.
#
# On a native VM (RUNTIME=native, see devaloy_runtime in common.sh) there is no
# entrypoint and no image. The daemons are systemd units there, so the docker,
# Paseo and T3 Code rows read the unit state instead, and two more rows check
# the units every native box has: tailscaled and the devaloy-boot oneshot.

DOCTOR_FAILURES=0

# Every row is one of ok / broken / off, and only `broken` moves the exit code.
doctor_rows=()

doctor_row() { # doctor_row <state> <label> <detail>
  doctor_rows+=("$1"$'\t'"$2"$'\t'"$3")
  [ "$1" = "broken" ] && DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
  return 0
}

doctor_gated() { # doctor_gated <flag> <label> <probe command...>
  # A capability behind a build flag. Absent by flag is fine; absent despite the
  # flag is a fault.
  local flag="$1" label="$2"
  shift 2
  case "$(build_flag "${flag}")" in
    false) doctor_row off "${label}" "not built with ${flag}" ;;
    true)
      if "$@" >/dev/null 2>&1; then
        doctor_row ok "${label}" "up"
      else
        doctor_row broken "${label}" "${flag}=true but the probe failed"
      fi
      ;;
    *)
      # An image built before build-flags existed. Report the probe, but never
      # fail on it: there is no way to know what was asked for.
      if "$@" >/dev/null 2>&1; then
        doctor_row ok "${label}" "up (build flags unknown)"
      else
        doctor_row off "${label}" "absent (build flags unknown — rebuild to record them)"
      fi
      ;;
  esac
}

browser_up() {
  dpkg -s libnss3 >/dev/null 2>&1
}

# --- native units -----------------------------------------------------------
#
# On a native VM the work the entrypoint does in a container belongs to systemd
# units, so the unit state is the thing to judge. A container has no systemd at
# all, which is why none of this runs there.
#
# One row per unit, and the detail names the unit and what is wrong with it
# (not installed, failed, inactive, never ran), so the fix is to read that
# unit's journal and not to guess which of five it was. A box with no systemd
# reachable (this check run with RUNTIME=native inside a container, or a VM
# booted without systemd) reports every unit as missing and says why, rather
# than failing on a container path.
DOCTOR_UNIT_TIMEOUT=5

unit_props() { # unit_props <unit> — prints Key=Value lines, or fails
  command -v systemctl >/dev/null 2>&1 || return 2
  timeout "${DOCTOR_UNIT_TIMEOUT}" systemctl show \
    -p LoadState -p ActiveState -p SubState -p Result \
    -p ExecMainStartTimestampMonotonic "$1" 2>/dev/null
}

unit_prop() { # unit_prop <props> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

doctor_unit() { # doctor_unit <label> <unit> [oneshot]
  local label="$1" unit="$2" kind="${3:-service}" props rc=0
  local load active sub result started
  props="$(unit_props "${unit}")" || rc=$?
  if [ "${rc}" -eq 2 ]; then
    doctor_row broken "${label}" "${unit} missing: systemctl is not on PATH"
    return 0
  fi
  if [ "${rc}" -ne 0 ] || [ -z "${props}" ]; then
    doctor_row broken "${label}" "${unit} missing: systemd is not running on this box"
    return 0
  fi
  load="$(unit_prop "${props}" LoadState)"
  active="$(unit_prop "${props}" ActiveState)"
  sub="$(unit_prop "${props}" SubState)"
  result="$(unit_prop "${props}" Result)"
  started="$(unit_prop "${props}" ExecMainStartTimestampMonotonic)"

  if [ "${load}" != "loaded" ]; then
    doctor_row broken "${label}" "${unit} missing (LoadState=${load:-unknown})"
    return 0
  fi

  if [ "${kind}" = "oneshot" ]; then
    # devaloy-boot runs once per boot and exits. Success is "it ran, and its
    # last run exited 0"; whether it stays active afterwards depends on
    # RemainAfterExit, so ActiveState alone cannot judge it. A run in progress
    # is the cold-volume toolchain bootstrap, which takes minutes, and is not a
    # fault yet.
    if [ "${active}" = "activating" ]; then
      doctor_row off "${label}" "${unit} still running — journalctl -u ${unit}"
    elif [ "${result}" != "success" ]; then
      doctor_row broken "${label}" "${unit} failed (Result=${result:-unknown}) — journalctl -u ${unit}"
    elif [ "${started:-0}" = "0" ]; then
      doctor_row broken "${label}" "${unit} has not run since boot"
    else
      doctor_row ok "${label}" "${unit} ran and succeeded"
    fi
    return 0
  fi

  if [ "${active}" = "active" ]; then
    doctor_row ok "${label}" "${unit} active (${sub:-running})"
  elif [ "${active}" = "failed" ]; then
    doctor_row broken "${label}" "${unit} failed (Result=${result:-unknown}) — journalctl -u ${unit}"
  else
    doctor_row broken "${label}" "${unit} is ${active:-unknown} — journalctl -u ${unit}"
  fi
}

# The native half of doctor_collect: the units the installer puts on the VM.
# tailscaled and devaloy-boot are always there. Docker, Paseo and T3 Code are
# there only when their flag is on, and a flag that is off is a row marked off,
# exactly as in the container. The flags come from runtime-flags (written by
# devaloy-boot on every boot from /etc/devaloy/env), with the environment
# winning, the same rule the container rows use.
doctor_collect_native_units() {
  doctor_unit 'tailscaled' tailscaled.service
  doctor_unit 'devaloy-boot' devaloy-boot.service oneshot

  if [ "$(runtime_flag WITH_DOCKER)" = "true" ]; then
    doctor_unit 'docker daemon' docker.service
  else
    doctor_row off 'docker daemon' 'WITH_DOCKER is off'
  fi
  if [ "$(runtime_flag WITH_PASEO)" = "true" ]; then
    doctor_unit 'paseo daemon' devaloy-paseo.service
  else
    doctor_row off 'paseo daemon' 'WITH_PASEO is off'
  fi
  if [ "$(runtime_flag WITH_T3CODE)" = "true" ]; then
    doctor_unit 't3 server' devaloy-t3code.service
  else
    doctor_row off 't3 server' 'WITH_T3CODE is off'
  fi
}

doctor_t3_push() {
  # Phone push for T3 Code goes through the T3 Connect relay only. Pairing over
  # the tailnet does not register the box with it, and the link needs a human
  # sign-in, so the boot cannot make it. This row reads the server's secret
  # files directly, the same files `t3 connect status` reads, because that
  # command takes about three seconds. Not linked is off: push is opt-in. Asked
  # for and not provisioned is broken, since the phone then stays silent.
  local dir="${T3CODE_HOME:-${HOME}/.t3}/userdata/secrets"
  if [ -f "${dir}/cloud-link-revoked.bin" ]; then
    doctor_row broken 't3 push' 'T3 Connect revoked the link, so run t3 connect link --publish-only --headless'
  elif [ ! -f "${dir}/cloud-linked-user-id.bin" ]; then
    if [ -f "${dir}/cloud-cli-desired-link.bin" ]; then
      doctor_row broken 't3 push' 'link authorized but not provisioned, so restart with devaloy ram --t3 --apply'
    else
      doctor_row off 't3 push' 'no T3 Connect link, so phones get no push (t3 connect link --publish-only --headless)'
    fi
  elif [ "$(cat "${dir}/cloud-publish-agent-activity.bin" 2>/dev/null)" != "true" ]; then
    doctor_row off 't3 push' 'publishing is off, so run t3 connect publish'
  else
    doctor_row ok 't3 push' 'linked to T3 Connect, publishing agent activity'
  fi
}

modules_present() {
  # The other half of the loader's hard fail: the loader proves the modules were
  # there at start, and this reports it as a row so a partial COPY is visible
  # rather than inferred from a missing verb.
  local m missing=0
  for m in ${DEVALOY_MODULES}; do
    [ -r "${DEVALOY_LIB}/${m}" ] || missing=$((missing + 1))
  done
  [ "${missing}" -eq 0 ]
}

doctor_collect() {
  DOCTOR_FAILURES=0
  doctor_rows=()

  if on_native; then
    doctor_collect_native_units
  else
    doctor_gated WITH_DOCKER 'docker daemon' docker info
  fi
  doctor_gated WITH_BROWSER 'browser capture' browser_up

  # Paseo, from the runtime flags rather than the build flags, and the running
  # daemon outranks the key. An old container with no runtime flags file reads
  # the key as false, and reporting a daemon that is plainly up as "off" would
  # be a lie the missing file happens to tell. On a VM the unit row above has
  # already judged the daemon, so only the CLI row below is added there.
  if on_native; then
    :
  elif [ -n "$(paseo_pids)" ]; then
    doctor_row ok 'paseo daemon' 'up'
  elif [ "$(runtime_flag WITH_PASEO)" = "true" ]; then
    doctor_row broken 'paseo daemon' 'WITH_PASEO=true but no daemon is running'
  else
    doctor_row off 'paseo daemon' 'not running, and WITH_PASEO is off'
  fi

  # The CLI, on its own row, because it fails apart from the daemon. A pruned
  # install leaves the running daemon untouched, since node holds the deleted
  # files open, while every `paseo` command on the box reports it is not
  # installed. One row for the pair would report that box as healthy.
  if [ "$(runtime_flag WITH_PASEO)" = "true" ] || [ -n "$(paseo_pids)" ]; then
    if command -v paseo >/dev/null 2>&1; then
      doctor_row ok 'paseo cli' "$(command -v paseo)"
    else
      doctor_row broken 'paseo cli' 'missing from PATH, so run devaloy update'
    fi
  fi

  # The T3 Code server, by the same rules as the Paseo rows above: a running
  # server outranks the key, and the CLI gets its own row because a pruned
  # install leaves a running server untouched. On a VM the unit row has
  # already judged the server.
  if on_native; then
    :
  elif [ -n "$(t3_pids)" ]; then
    doctor_row ok 't3 server' 'up'
  elif [ "$(runtime_flag WITH_T3CODE)" = "true" ]; then
    doctor_row broken 't3 server' 'WITH_T3CODE=true but no server is running'
  else
    doctor_row off 't3 server' 'not running, and WITH_T3CODE is off'
  fi
  if [ "$(runtime_flag WITH_T3CODE)" = "true" ] || [ -n "$(t3_pids)" ]; then
    if command -v t3 >/dev/null 2>&1; then
      doctor_row ok 't3 cli' "$(command -v t3)"
    else
      doctor_row broken 't3 cli' 'missing from PATH, so run devaloy update'
    fi
    doctor_t3_push
  fi

  # Things that are always meant to be here, so absent is always a fault.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    doctor_row ok 'github auth' 'GITHUB_TOKEN is set — do not run gh auth login'
  else
    doctor_row off 'github auth' 'GITHUB_TOKEN is unset; gh may need its own login'
  fi

  if tailscale status >/dev/null 2>&1; then
    doctor_row ok 'tailscale' "$(tailscale status 2>/dev/null | head -1 | awk '{print $2}')"
  else
    doctor_row broken 'tailscale' 'not reachable — this is the only way into the box'
  fi

  if [ -d "${HOME}/.local/share/mise/shims" ]; then
    local linked
    linked="$(find /usr/local/bin -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
    doctor_row ok 'mise shims' "${linked} tool(s) mirrored into /usr/local/bin"
  else
    doctor_row broken 'mise shims' 'no shim directory — run devaloy update'
  fi

  if fzf_version_ok; then
    doctor_row ok 'fzf' "$(fzf --version 2>/dev/null | awk '{print $1}') — the TUI runs"
  else
    doctor_row broken 'fzf' "$(fzf --version 2>/dev/null | awk '{print $1}' || echo absent), below 0.${FZF_FLOOR_MINOR} — run devaloy update"
  fi

  local count
  # Unquoted on purpose: one line per module name.
  # shellcheck disable=SC2086
  count="$(printf '%s\n' ${DEVALOY_MODULES} | wc -l | tr -d ' ')"
  if modules_present; then
    doctor_row ok 'devaloy modules' "${count} of ${count} present in ${DEVALOY_LIB}"
  else
    doctor_row broken 'devaloy modules' "a module is missing from ${DEVALOY_LIB}"
  fi
}

doctor_icon() {
  case "$1" in
    ok) printf '%s✓%s' "${GREEN}" "${RESET}" ;;
    broken) printf '%s✗%s' "${RED}" "${RESET}" ;;
    *) printf '%s·%s' "${DIM}" "${RESET}" ;;
  esac
}

rows_doctor() {
  doctor_collect
  local r state label detail
  emit_head 'capabilities' "$(devaloy_runtime), checked at $(now_stamp)"
  for r in "${doctor_rows[@]}"; do
    state="${r%%$'\t'*}"
    label="$(printf '%s' "${r}" | cut -f2)"
    detail="$(printf '%s' "${r}" | cut -f3)"
    emit_row "$(doctor_icon "${state}")" "${label}" "${detail}"
  done
  if [ "${DOCTOR_FAILURES}" -eq 0 ]; then
    emit_hint "${GREEN}nothing broken${RESET}${DIM} — a row marked · is off by design${RESET}"
  else
    emit_hint "${RED}${DOCTOR_FAILURES} broken${RESET}${DIM} — built in, but not working${RESET}"
  fi
}

doctor_report() {
  do_doctor || true
}

do_doctor() {
  doctor_collect
  local r state label detail
  printf 'devaloy doctor: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  # The runtime decides which checks ran (entrypoint processes or systemd
  # units), so it heads the report: a reader comparing two boxes sees first
  # whether the rows below can be compared at all.
  printf 'runtime: %s\n\n' "$(devaloy_runtime)"
  for r in "${doctor_rows[@]}"; do
    state="${r%%$'\t'*}"
    label="$(printf '%s' "${r}" | cut -f2)"
    detail="$(printf '%s' "${r}" | cut -f3)"
    printf '  %s  %-18s %s\n' "$(doctor_icon "${state}")" "${label}" "${detail}"
  done
  printf '\n'
  if [ "${DOCTOR_FAILURES}" -eq 0 ]; then
    printf 'devaloy doctor: nothing broken. A row marked · is off by design.\n'
    return 0
  fi
  printf 'devaloy doctor: %s capability(ies) built in but not working.\n' "${DOCTOR_FAILURES}"
  return 1
}

# --- health ---------------------------------------------------------------
#
# The Docker HEALTHCHECK in the Dockerfile runs this, and it answers one
# question: can you get into the box? Doctor answers a wider one, and that is
# why this is not `doctor`. A healthcheck exec runs as root with HOME=/root, so
# doctor's mise-shims row would fail on every box, and a failed toolchain
# bootstrap leaves the box reachable and repairable with `devaloy update`.
# Paseo and T3 Code stay out for the same reason: either can die while SSH
# still works, and doctor reports them.
#
# Two probes, each bounded, because a hung probe should fail by name rather
# than as an anonymous healthcheck timeout:
#
#   tailscale   BackendState is Running. Not .Health or .Self.Online, which
#               flap during a DERP or control-plane outage while existing
#               connections keep working.
#   docker      `docker info` answers, but only where the entrypoint starts
#               dockerd: the runtime key is on and the binary is in the image.
#               Everywhere else the probe is skipped, not failed.
#
# Quiet on success, one line per failure on stderr, exit 0 or 1. Docker keeps
# that output in .State.Health.Log, so the line has to name the fault.
#
# On a native VM nothing runs this as a healthcheck, but the question is the
# same and so is the tailscale probe. What changes is who keeps the daemons up:
# systemd, not the entrypoint. So the native path asks systemd whether the
# units are active (tailscaled always, docker when WITH_DOCKER=true) instead of
# looking for /usr/bin/dockerd, which the container check uses to tell an image
# with Docker from one without.
HEALTH_TIMEOUT=5

health_tailscale() {
  timeout "${HEALTH_TIMEOUT}" tailscale status --json 2>/dev/null |
    jq -e '.BackendState == "Running"' >/dev/null 2>&1
}

health_docker_expected() {
  [ "$(runtime_flag WITH_DOCKER)" = "true" ] && [ -x /usr/bin/dockerd ]
}

health_unit_active() { # health_unit_active <unit>
  timeout "${HEALTH_TIMEOUT}" systemctl is-active --quiet "$1" 2>/dev/null
}

do_health_native() {
  local failures=0
  if ! health_unit_active tailscaled.service; then
    printf 'devaloy health: tailscaled.service is not active\n' >&2
    failures=$((failures + 1))
  fi
  if ! health_tailscale; then
    printf 'devaloy health: tailscale backend is not Running\n' >&2
    failures=$((failures + 1))
  fi
  if [ "$(runtime_flag WITH_DOCKER)" = "true" ] &&
    ! health_unit_active docker.service; then
    printf 'devaloy health: docker.service is not active\n' >&2
    failures=$((failures + 1))
  fi
  [ "${failures}" -eq 0 ]
}

do_health() {
  if on_native; then
    do_health_native
    return
  fi
  local failures=0
  if ! health_tailscale; then
    printf 'devaloy health: tailscale backend is not Running\n' >&2
    failures=$((failures + 1))
  fi
  if health_docker_expected &&
    ! timeout "${HEALTH_TIMEOUT}" docker info >/dev/null 2>&1; then
    printf 'devaloy health: docker daemon is not answering\n' >&2
    failures=$((failures + 1))
  fi
  [ "${failures}" -eq 0 ]
}
