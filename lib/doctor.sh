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
# WITH_PASEO is not in the flags file on purpose. It is a runtime variable that
# `docker compose up -d` can flip without a rebuild, so an image-baked answer
# would be wrong; it comes from the environment instead.

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

orca_up() {
  command -v orca-ide >/dev/null 2>&1 && pgrep -f "orca-ide.*serve" >/dev/null 2>&1
}

browser_up() {
  dpkg -s libnss3 >/dev/null 2>&1
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

  doctor_gated WITH_DOCKER 'docker daemon' docker info
  doctor_gated WITH_ORCA 'orca runtime' orca_up
  doctor_gated WITH_BROWSER 'browser capture' browser_up

  # Paseo, from the environment rather than the flags file, and the running
  # daemon outranks the variable. entrypoint.sh exports WITH_PASEO into
  # interactive shells, but a cron line or `ssh devaloy '<cmd>'` does not get
  # it, and reporting a daemon that is plainly up as "off" would be a lie the
  # environment happens to tell.
  if [ -n "$(paseo_pids)" ]; then
    doctor_row ok 'paseo daemon' 'up'
  elif [ "${WITH_PASEO:-false}" = "true" ]; then
    doctor_row broken 'paseo daemon' 'WITH_PASEO=true but no daemon is running'
  else
    doctor_row off 'paseo daemon' 'not running, and WITH_PASEO is not set here'
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
  emit "  ${BOLD}capabilities${RESET}   ${DIM}checked at $(now_stamp)${RESET}"
  for r in "${doctor_rows[@]}"; do
    state="${r%%$'\t'*}"
    label="$(printf '%s' "${r}" | cut -f2)"
    detail="$(printf '%s' "${r}" | cut -f3)"
    emit_row "$(doctor_icon "${state}")" "${label}" "${detail}"
  done
  emit_rule
  if [ "${DOCTOR_FAILURES}" -eq 0 ]; then
    emit "  ${GREEN}nothing broken${RESET}${DIM} — a row marked · is off by design${RESET}"
  else
    emit "  ${RED}${DOCTOR_FAILURES} broken${RESET}${DIM} — built in, but not working${RESET}"
  fi
}

doctor_report() {
  do_doctor || true
}

do_doctor() {
  doctor_collect
  local r state label detail
  printf 'devaloy doctor: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
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
