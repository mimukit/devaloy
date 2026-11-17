#!/usr/bin/env bash
# devaloy boot steps: the Claude usage proxy for T3 Code
# (WITH_T3CODE_PROXY_CLAUDE_USAGE).
#
# Sourced by entrypoint.sh after common.sh, never executed. The restart loop
# stays in entrypoint.sh, like the other long-running processes. The step
# itself is runtime-neutral, so a native or Upstash boot can call it later.
#
# A box that signs in to Claude with CLAUDE_CODE_OAUTH_TOKEN shows no Claude
# group in the T3 Code Limits modal: T3 v0.1.10 asks api/oauth/usage, which
# refuses the setup-token. T3 also accepts a "cliproxy" usage-limit source.
# config/bin/t3-claude-usage-proxy answers that source's two management calls
# from `usage --json`, which reads local caches only and sends no request.
#
# This step does the on-disk half:
#
#   * the key, ~/.config/t3-claude-usage-proxy/key (dir 0700, file 0600),
#     created once and never rotated by a boot. The proxy reads it and never
#     creates it.
#   * one entry in T3's ~/.t3/userdata/settings.json,
#     .usageLimitSources["devaloy-claude-usage"]. jq changes that key and
#     nothing else. Every other key stays byte-equal.
#
# T3 moves an inline managementKey into its secret store on every load
# (secrets/usage-limit-source-<base64url(id)>.bin) and writes a placeholder
# in its place. So on a later boot the entry no longer holds the key, and the
# step compares T3's secret file with the key file instead. The step only
# reads that secret file, never writes it.
#
# With the flag off, or on a /login box with no token, the step removes the
# entry and starts nothing. A /login box reads Claude limits natively, and the
# entry would show Claude twice.

# The T3 version whose cliproxy contract the proxy was checked against.
# `devaloy doctor` warns when `t3 --version` differs.
# shellcheck disable=SC2034  # read by lib/doctor.sh, not by this file.
T3_CLAUDE_USAGE_TESTED=0.1.10

T3_CLAUDE_USAGE_PORT=8317
T3_CLAUDE_USAGE_ID="devaloy-claude-usage"
T3_CLAUDE_USAGE_LABEL="Claude (token)"
T3_CLAUDE_USAGE_KEY_DIR="${DEV_HOME}/.config/t3-claude-usage-proxy"
T3_CLAUDE_USAGE_KEY="${T3_CLAUDE_USAGE_KEY_DIR}/key"
# shellcheck disable=SC2034  # read by entrypoint.sh, not by this file.
T3_CLAUDE_USAGE_LOG="/var/log/devaloy-claude-usage-proxy.log"
T3_CLAUDE_USAGE_SETTINGS="${DEV_HOME}/.t3/userdata/settings.json"

# The secret file T3 keeps the entry's managementKey in. T3 names it with
# Buffer.from(id).toString("base64url"): URL-safe alphabet, no padding.
t3_claude_usage_secret_file() {
  local enc
  enc="$(printf '%s' "${T3_CLAUDE_USAGE_ID}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  printf '%s/.t3/userdata/secrets/usage-limit-source-%s.bin' "${DEV_HOME}" "${enc}"
}

# t3_claude_usage_commit <jq filter> [jq args …] — apply one jq filter to
# settings.json. Copies the file to settings.json.devaloy-bak first, writes a
# temp file in the same directory with the old mode and owner, then renames
# it over the file, so T3's watcher never reads half a file. Fails, and leaves
# the file alone, when jq fails.
t3_claude_usage_commit() {
  local file="${T3_CLAUDE_USAGE_SETTINGS}" tmp
  tmp="$(mktemp "${file}.devaloy-XXXXXX")" || return 1
  if ! jq "$@" "${file}" > "${tmp}" 2>/dev/null || [ ! -s "${tmp}" ]; then
    rm -f -- "${tmp}"
    return 1
  fi
  if ! cp -p -- "${file}" "${file}.devaloy-bak"; then
    rm -f -- "${tmp}"
    return 1
  fi
  chmod --reference="${file}" -- "${tmp}" 2>/dev/null || true
  chown --reference="${file}" -- "${tmp}" 2>/dev/null || true
  mv -f -- "${tmp}" "${file}"
}

# shellcheck disable=SC2016  # $id is a jq variable, not a shell one.
# Removes the entry when it is there. A missing file, a missing entry or a
# file that is not valid JSON is left as it is.
t3_claude_usage_remove() {
  local file="${T3_CLAUDE_USAGE_SETTINGS}"
  [ -f "${file}" ] || return 0
  jq -e --arg id "${T3_CLAUDE_USAGE_ID}" \
    '(.usageLimitSources | type) == "object" and (.usageLimitSources | has($id))' \
    "${file}" >/dev/null 2>&1 || return 0
  if t3_claude_usage_commit --arg id "${T3_CLAUDE_USAGE_ID}" \
      'del(.usageLimitSources[$id])'; then
    log "T3 Code: removed the ${T3_CLAUDE_USAGE_ID} usage-limit source"
  else
    log "WARNING: could not remove the ${T3_CLAUDE_USAGE_ID} entry from ${file}."
  fi
}

# Sets T3_CLAUDE_USAGE_READY=1 when the proxy should start: the flag is on, a
# token is set, the key exists and the settings entry is in place.
step_t3_claude_usage_config() {
  local file="${T3_CLAUDE_USAGE_SETTINGS}" url secret entry key
  T3_CLAUDE_USAGE_READY=0
  url="http://127.0.0.1:${T3_CLAUDE_USAGE_PORT}"

  if [ "${WITH_T3CODE_PROXY_CLAUDE_USAGE:-false}" != "true" ]; then
    t3_claude_usage_remove
    return 0
  fi
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    t3_claude_usage_remove
    log "WARNING: WITH_T3CODE_PROXY_CLAUDE_USAGE is true, but CLAUDE_CODE_OAUTH_TOKEN"
    log "WARNING: is empty. A /login box reads Claude limits in T3 Code natively,"
    log "WARNING: so the Claude usage proxy does not start."
    return 0
  fi

  # The key. Written by the dev user under umask 077, so the directory is
  # 0700 and the file 0600 from the first byte. od, not openssl: coreutils is
  # on every runtime.
  if ! as_dev "umask 077; mkdir -p $(sq "${T3_CLAUDE_USAGE_KEY_DIR}") && \
      chmod 700 $(sq "${T3_CLAUDE_USAGE_KEY_DIR}") && \
      if [ ! -s $(sq "${T3_CLAUDE_USAGE_KEY}") ]; then \
        k=\$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n') && \
        printf '%s\n' \"\$k\" > $(sq "${T3_CLAUDE_USAGE_KEY}.tmp") && \
        mv -f $(sq "${T3_CLAUDE_USAGE_KEY}.tmp") $(sq "${T3_CLAUDE_USAGE_KEY}"); \
      fi" || [ ! -s "${T3_CLAUDE_USAGE_KEY}" ]; then
    log "WARNING: could not create ${T3_CLAUDE_USAGE_KEY}."
    log "WARNING: the Claude usage proxy does not start."
    return 0
  fi
  key="$(cat -- "${T3_CLAUDE_USAGE_KEY}")"

  # T3 creates settings.json on its first start. On a box where it never ran,
  # the step writes a file with this one key: T3 reads a sparse file and fills
  # in its defaults.
  if [ ! -f "${file}" ]; then
    if ! as_dev "mkdir -p $(sq "${file%/*}") && \
        { [ -f $(sq "${file}") ] || printf '{}\n' > $(sq "${file}"); }"; then
      log "WARNING: could not create ${file}."
      log "WARNING: the Claude usage proxy does not start."
      return 0
    fi
  fi

  if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
    log "WARNING: ${file} is not a valid JSON object. It is left as it is,"
    log "WARNING: and the Claude usage proxy does not start. Fix or delete the"
    log "WARNING: file, then restart."
    return 0
  fi

  # Leave the file alone when the entry already points at the proxy and holds
  # the key: inline (T3 has not loaded it yet) or in T3's secret store.
  entry="$(jq -c --arg id "${T3_CLAUDE_USAGE_ID}" \
    '.usageLimitSources[$id]? // empty' "${file}" 2>/dev/null || true)"
  secret="$(t3_claude_usage_secret_file)"
  if [ -n "${entry}" ] &&
     printf '%s' "${entry}" | jq -e --arg label "${T3_CLAUDE_USAGE_LABEL}" \
       --arg url "${url}" \
       'type == "object" and .kind == "cliproxy" and .label == $label
        and .url == $url and .enabled == true' >/dev/null 2>&1 &&
     { [ "$(printf '%s' "${entry}" | jq -r '.managementKey // ""')" = "${key}" ] ||
       { [ -f "${secret}" ] && [ "$(cat -- "${secret}" 2>/dev/null)" = "${key}" ]; }; }; then
    T3_CLAUDE_USAGE_READY=1
    return 0
  fi

  # --rawfile, not --arg, so the key never shows in a process list.
  # shellcheck disable=SC2016  # $id, $label, $url, $key are jq variables.
  if t3_claude_usage_commit --arg id "${T3_CLAUDE_USAGE_ID}" \
      --arg label "${T3_CLAUDE_USAGE_LABEL}" --arg url "${url}" \
      --rawfile key "${T3_CLAUDE_USAGE_KEY}" \
      '.usageLimitSources[$id] = {kind: "cliproxy", label: $label, url: $url,
         managementKey: ($key | rtrimstr("\n")), enabled: true}'; then
    log "T3 Code: wrote the ${T3_CLAUDE_USAGE_ID} usage-limit source (${url})"
    T3_CLAUDE_USAGE_READY=1
  else
    log "WARNING: could not write the ${T3_CLAUDE_USAGE_ID} entry to ${file}."
    log "WARNING: the Claude usage proxy does not start."
  fi
}
