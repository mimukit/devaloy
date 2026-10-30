#!/usr/bin/env bash
# devaloy boot steps: the Paseo daemon's config file and its plugins.
#
# Sourced by entrypoint.sh after common.sh, never executed. The daemon's
# restart loop stays in entrypoint.sh. Both steps here expect PASEO_IP (the
# tailnet IPv4) and PASEO_PORT to be set by the caller.

# --- the daemon's config file (~/.paseo/config.json) ---
# The daemon would start from flags alone. Everything ELSE on the box
# would not: `paseo ls` over SSH, `paseo daemon restart` after you change
# something, and the MCP endpoint all read this file to find the daemon,
# and Paseo's own default is 127.0.0.1:6767. Flags fix the one process
# started here and leave every other caller talking to nothing. So the
# settings live in the file and the start command in entrypoint.sh carries
# none.
#
# The tailnet address is the reason this is written at boot rather than
# shipped: the IP is assigned by the tailnet and is not knowable at build
# time. It also runs HERE rather than in step_seed_config, which is where
# every other config/ directory is seeded, because it needs PASEO_IP and
# `tailscale up` has not run yet at that point in the boot.
#
# Three layers, each overriding the one before:
#
#   1. the file already in the home volume — what the Paseo app itself
#      wrote, and what you edited on the box
#   2. config/paseo/config.json from the repo
#   3. the values derived here from the container environment
#
# jq's `*` merges objects recursively and REPLACES arrays whole, and that
# split is the whole design. A terminal profile you create in the app
# lands under a key the repo does not ship, so it survives a redeploy. An
# array the repo does ship, like cors.allowedOrigins, is reset from the
# repo on every boot, so the repo really is the source of truth for it.
#
# daemon.hostnames is set unconditionally, including when the web UI is
# off, and that is safe: Paseo's check allows localhost, *.localhost and
# every IP address BEFORE it consults this list, so the list only ever
# adds names. It cannot cost the phone its connection to a bare IP. The
# check also gates the WebSocket upgrade rather than only the web UI, so
# setting it with the UI off is what lets a client reach the daemon at
# its MagicDNS name instead of collecting a 403.
#
# Writing it conditionally is what would bite: the merge keeps keys it is
# not given, so a boot with the UI off would inherit the hostnames from a
# boot with it on, and turning the key off would not take effect.
#
# PASEO_PASSWORD stays OUT of this file and in ~/.devaloy_secrets, which
# the start command in entrypoint.sh sources. daemon.auth.password takes a
# bcrypt hash and nothing else; the environment variable takes the plaintext
# and the daemon hashes it at startup. Writing the plaintext here would fail
# the schema, and hashing it here would put a credential in a file the
# app rewrites.
#
# Sets PASEO_WEB_UI and PASEO_START_ENV as globals. The daemon loop reads
# PASEO_START_ENV, which stays empty unless the config write fails.
step_paseo_config() {
  # The web UI is a second, separate key: it serves a full browser client
  # from the daemon's own origin, and the static files load without auth.
  PASEO_WEB_UI=false
  if [ "${WITH_PASEO_WEB_UI:-false}" = "true" ]; then
    PASEO_WEB_UI=true
    if [ -z "${PASEO_PASSWORD:-}" ]; then
      # Warn, then serve anyway. Withholding the UI would cost a working
      # surface over a configuration choice, and gating only the UI while
      # the WebSocket API stays open on the same address protects nothing.
      log "WARNING: WITH_PASEO_WEB_UI is on and PASEO_PASSWORD is empty."
      log "WARNING: anything that can reach ${PASEO_IP} gets a full browser"
      log "WARNING: client and an unauthenticated API. Set PASEO_PASSWORD in"
      if on_native; then
        log "WARNING: /etc/devaloy/env and run 'sudo systemctl restart devaloy-boot"
        log "WARNING: devaloy-paseo', or turn the web UI back off."
      else
        log "WARNING: .env and redeploy, or turn the web UI back off."
      fi
    fi
  fi

  PASEO_CONFIG="${DEV_HOME}/.paseo/config.json"
  # `jq -c .` on a file that is missing, truncated or half-written exits
  # non-zero and the fallback takes over; the type test catches the rest,
  # because a file holding `null` parses fine and then cannot be merged.
  PASEO_CUR="$(jq -c 'if type == "object" then . else {} end' \
    "${PASEO_CONFIG}" 2>/dev/null || printf '{}')"
  PASEO_REPO="$(jq -c 'if type == "object" then . else {} end' \
    "${CONFIG_SRC}/paseo/config.json" 2>/dev/null || printf '{}')"
  PASEO_MERGED="$(jq -nc \
    --argjson cur "${PASEO_CUR}" \
    --argjson repo "${PASEO_REPO}" \
    --arg listen "${PASEO_IP}:${PASEO_PORT}" \
    --arg hostnames "${TS_HOSTNAME:-devaloy},.ts.net" \
    --argjson webui "${PASEO_WEB_UI}" \
    '$cur * $repo * {
       daemon: { listen: $listen, hostnames: ($hostnames | split(",")) },
       features: { webUi: { enabled: $webui } }
     }' 2>/dev/null || true)"

  # Every step here ends in `|| true` or sits inside the `if` condition, so
  # `set -e` cannot take the entrypoint down over a config file. The whole
  # Paseo block is non-fatal by design, and aborting here would stop a container that
  # is otherwise up and reachable over SSH.
  PASEO_START_ENV=""
  mkdir -p "${DEV_HOME}/.paseo" 2>/dev/null || true
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.paseo" 2>/dev/null || true
  # commit_staged (common.sh) rather than a bare mv, so a boot that merges to
  # the same bytes leaves the file and its mtime alone.
  if [ -n "${PASEO_MERGED}" ] &&
     printf '%s\n' "${PASEO_MERGED}" | jq . > "${PASEO_CONFIG}.tmp" 2>/dev/null &&
     commit_staged "${PASEO_CONFIG}.tmp" "${PASEO_CONFIG}"; then
    chown "${DEV_USER}:${DEV_USER}" "${PASEO_CONFIG}" 2>/dev/null || true
    log "Paseo config written to ~/.paseo/config.json (listen ${PASEO_IP}:${PASEO_PORT})"
  else
    # Fall back to the flags this block used before the config file existed.
    # The daemon comes up on the right address either way; what is lost is
    # `paseo` on the box finding it, so the warning says which half broke.
    rm -f "${PASEO_CONFIG}.tmp" 2>/dev/null || true
    log "WARNING: could not write ~/.paseo/config.json. Starting the daemon"
    log "WARNING: from flags instead — it will bind the right address, but"
    log "WARNING: 'paseo ls' on the box needs --host ${PASEO_IP}:${PASEO_PORT}."
    PASEO_START_ENV="export PASEO_RELAY_ENABLED=false PASEO_LISTEN='${PASEO_IP}:${PASEO_PORT}';"
    if [ "${PASEO_WEB_UI}" = "true" ]; then
      PASEO_START_ENV="${PASEO_START_ENV} export PASEO_WEB_UI_ENABLED=true PASEO_HOSTNAMES='${TS_HOSTNAME:-devaloy},.ts.net';"
    fi
  fi
}

# --- install the plugins named in PASEO_PLUGINS ---
# Plugins are the one part of the Paseo setup that config/paseo/config.json
# cannot carry. The config file records a plugin AFTER it is installed, and
# a git-sourced plugin also needs its clone under ~/.paseo/plugins, which
# only `paseo plugin install` creates. So this drives the CLI rather than
# writing the key.
#
# The caller runs it in the BACKGROUND and after the daemon loop, because
# `paseo plugin install` talks to the daemon and the daemon is not up yet
# when the loop has just been started. Running it in the foreground would hold
# the entrypoint short of the `wait` at the bottom of entrypoint.sh for as long
# as the daemon takes to answer, and a daemon that never answers would cost
# you the SSH you would fix it from.
step_paseo_plugins() {
  # Every CLI call below has to carry the SAME environment the daemon
  # loop starts the daemon with, and PASEO_PASSWORD is the reason.
  # With a password set, the daemon closes an unauthenticated websocket
  # (`Transport closed (code 1006)`), and the CLI reads the password from
  # its own environment — there is no key for it in ~/.paseo/config.json.
  # as_dev runs `su -l -s /bin/sh`, which reads neither .zshenv nor
  # .bashrc, so without this prefix every call here fails, the probe
  # below burns its full 120s, and no plugin is ever installed.
  #
  # The `if [ -f ]` guard is load-bearing for the same dash reason spelt
  # out at the daemon loop: `.` is a special builtin, so a missing file
  # exits the shell before `||` is considered.
  paseo_env="if [ -f '${SECRETS_SNIPPET}' ]; then . '${SECRETS_SNIPPET}'; fi;"

  # Wait for the daemon to answer, up to two minutes. `plugin ls` is the
  # probe rather than `daemon status`, because it is also the call the
  # loop below needs to succeed — a daemon that is up but not yet serving
  # the plugin API would pass a status check and then fail every install.
  plugin_ls=""
  waited=0
  while [ "${waited}" -lt 120 ]; do
    if plugin_ls="$(as_dev "${paseo_env} paseo plugin ls --json" 2>/dev/null)" &&
       printf '%s' "${plugin_ls}" | jq -e 'type == "array"' >/dev/null 2>&1; then
      break
    fi
    plugin_ls=""
    waited=$((waited + 2))
    sleep 2
  done
  if [ -z "${plugin_ls}" ]; then
    log "WARNING: the Paseo daemon did not answer in 120s — PASEO_PLUGINS"
    log "WARNING: not installed. Check the daemon lines above first, then"
    log "WARNING: PASEO_PASSWORD: a wrong password closes the socket with"
    log "WARNING: 'Transport closed (code 1006)' rather than an auth error."
    log "WARNING: Install them by hand with 'paseo plugin install"
    if on_native; then
      log "WARNING: <source>', or run 'sudo systemctl restart devaloy-boot'."
    else
      log "WARNING: <source>', or restart the container."
    fi
    # return, not exit: the entrypoint runs this in a background subshell,
    # where the two are the same, but a foreground caller must not die here.
    return 0
  fi

  # Same split as DEVALOY_REPOS, for the same reason — see the long note
  # on `set -f` in step_clone_repos.
  set -f
  # shellcheck disable=SC2086  # the split is the point.
  set -- ${PASEO_PLUGINS}
  set +f

  for spec in "$@"; do
    # Same whitelist as DEVALOY_REPOS, plus `=` for the id prefix. Every
    # install below reaches the CLI through as_dev, which is `su -c` on
    # ONE string.
    case "${spec}" in
      *[!A-Za-z0-9._:/@+~=-]*)
        log "WARNING: PASEO_PLUGINS entry '${spec}' has an illegal"
        log "WARNING: character — skipped."
        continue
        ;;
    esac

    # `id=source` pins the runtime id; a bare source derives it. The
    # derived id is the last path segment with any .git stripped, which
    # is the manifest id for every plugin laid out one-per-directory.
    # Pin it explicitly when a plugin's manifest id differs from its
    # directory name, because a wrong guess here reinstalls a plugin
    # that is already installed on every boot.
    case "${spec}" in
      *=*)
        plugin_id="${spec%%=*}"
        plugin_src="${spec#*=}"
        ;;
      *)
        plugin_src="${spec}"
        plugin_id="${plugin_src%/}"
        plugin_id="${plugin_id##*/}"
        plugin_id="${plugin_id##*:}"
        plugin_id="${plugin_id%.git}"
        ;;
    esac
    if [ -z "${plugin_id}" ] || [ -z "${plugin_src}" ]; then
      log "WARNING: PASEO_PLUGINS entry '${spec}' names no plugin — skipped."
      continue
    fi

    # Already installed: silent, like the DEVALOY_REPOS skip. This block
    # runs on every boot, and a redeploy should not reinstall a plugin
    # you have since disabled in the app.
    if printf '%s' "${plugin_ls}" |
       jq -e --arg id "${plugin_id}" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
      continue
    fi

    if as_dev "${paseo_env} paseo plugin install $(sq "${plugin_src}") --id $(sq "${plugin_id}")" \
       >/dev/null 2>&1; then
      log "Paseo plugin '${plugin_id}' installed from ${plugin_src}"
    else
      # Non-fatal, like every other failure in the Paseo block. The most
      # common cause is a private repo with no credentials on the box.
      log "WARNING: could not install Paseo plugin '${plugin_id}' from"
      log "WARNING: ${plugin_src}. Run 'paseo plugin install' on the box"
      log "WARNING: to see why."
    fi
  done
}
