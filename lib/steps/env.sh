#!/usr/bin/env bash
# devaloy boot steps: the dev user's shell environment, secrets and dotfiles.
#
# Sourced by entrypoint.sh after common.sh, never executed. These all run
# before tailscaled starts, so the first session that lands finds them in
# place.

# --- shell env: toolchain PATH + OOM reset, for EVERY shell ---
# Written before tailscaled comes up, so the very first session that lands
# already has it. Ubuntu's stock .bashrc bails out early on non-interactive
# shells, so this is sourced from the TOP of .bashrc, above that guard; for zsh
# it hangs off .zshenv, which zsh sources for *every* invocation including
# `ssh devaloy '<cmd>'`. mise shims resolve versions at exec time, so no
# interactive `mise activate` is needed. link-shims covers whatever is left.
#
# This writes the staging copy only. step_browser_env appends to it, and
# step_shell_hooks puts it in place (see commit_staged), hands it to the dev
# user and hooks it into .bashrc and .zshenv, in that order.
step_shell_env() {
  cat > "${ENV_SNIPPET}${STAGED}" <<'EOF'
# Idempotent: this file is reachable from .zshenv, .zshrc and .bashrc, and a
# blind prepend would stack duplicate entries onto PATH on every nested shell.
# Listed back-to-front because each iteration prepends: the last one processed
# ends up first, and ~/.local/bin has to win — it is where a hand-run vendor
# installer puts things, and that copy should shadow the packaged one.
for _devaloy_dir in "$HOME/.local/share/mise/shims" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_devaloy_dir:"*) ;;
    *) PATH="$_devaloy_dir:$PATH" ;;
  esac
done
unset _devaloy_dir
export PATH

# mise holds back any release younger than its `minimum_release_age` window
# (24h by default) as a supply-chain cooling-off period. On this box the delay
# only produced noise: every tool here tracks latest, `mise upgrade` warned
# about the release it refused to take, and the agent CLIs ship most days, so
# mise's "latest" stayed one release behind the version the CLI itself checked.
# 0 turns the window off for every tool.
#
# Exported here so any upgrade you run by hand sees it from any shell.
# bootstrap-toolchain.sh exports it again for the boot path, which runs under
# `su -l -s /bin/sh` and never sources this file.
export MISE_MINIMUM_RELEASE_AGE=0s

# Tokens live in a separate 0600 file so this one stays safe to cat.
[ -f "$HOME/.devaloy_secrets" ] && . "$HOME/.devaloy_secrets"

# The container starts at a negative oom_score_adj (see compose.yml) to keep
# tailscaled off the OOM killer's list. Raise every session back to 0 so a
# runaway build inherits 0 and is killed before the process that keeps you
# connected. Raising is unprivileged; only lowering needs CAP_SYS_RESOURCE.
echo 0 > /proc/self/oom_score_adj 2>/dev/null || true
EOF
}

# --- browser defaults (only when WITH_BROWSER=true) ---
# Appended after the heredoc in step_shell_env rather than inside it, because
# that heredoc is quoted and this block is conditional. Three defaults, each one
# correcting what `playwright-cli` would otherwise do on this box, read from the
# source of @playwright/cli 0.1.19 (playwright-core 1.63):
#
#   PLAYWRIGHT_MCP_BROWSER=chromium    A bare `playwright-cli open` launches
#                                      Google Chrome, which this image does not
#                                      carry. `chromium` selects the Chrome for
#                                      Testing build the bootstrap downloaded.
#   PLAYWRIGHT_MCP_SANDBOX=probed      On Linux, for the bundled Chromium,
#                                      Playwright sets chromiumSandbox=false by
#                                      default and pushes --no-sandbox onto the
#                                      launch. `true` keeps Chromium's own
#                                      sandbox ON, which needs the dev user to
#                                      create a user namespace. Under runc that
#                                      works, because compose sets
#                                      seccomp=unconfined. Under sysbox-runc it
#                                      does not (measured: `unshare -Ur` fails
#                                      writing uid_map), and with `true` every
#                                      launch dies on "Chromium sandboxing
#                                      failed!". So the value is whatever an
#                                      `unshare -Ur true` probe as the dev user
#                                      says, decided once per boot.
#   PLAYWRIGHT_MCP_OUTPUT_DIR          A bare `screenshot` writes to
#                                      .playwright-cli/ under the cwd, which is
#                                      a repo in the home volume. /tmp is shared
#                                      with the Paseo daemon in this container,
#                                      so the printed path is what Paseo opens,
#                                      and the files die with the container.
#
# Nothing here needs the libraries or the browser to be present, so it is
# written before the toolchain check rather than after it.
step_browser_env() {
  if [ "${WITH_BROWSER:-false}" = "true" ]; then
    if as_dev 'unshare -Ur true' >/dev/null 2>&1; then
      _pw_sandbox=true
    else
      _pw_sandbox=false
      log "browser: no user namespace for ${DEV_USER}, so Chromium runs with --no-sandbox"
    fi
    cat >> "${ENV_SNIPPET}${STAGED}" <<EOF

# Browser capture defaults (WITH_BROWSER=true) — see entrypoint.sh for why each.
# PLAYWRIGHT_MCP_SANDBOX is probed at boot: true only when the dev user can
# create a user namespace, which Chromium's sandbox needs.
export PLAYWRIGHT_MCP_BROWSER=chromium
export PLAYWRIGHT_MCP_SANDBOX=${_pw_sandbox}
export PLAYWRIGHT_MCP_OUTPUT_DIR=/tmp/playwright-cli
EOF
    unset _pw_sandbox
  fi
}

# Puts ~/.devaloy_env in place, hands it to the dev user and sources it from
# the top of .bashrc and from .zshenv. See step_shell_env for why those two
# files.
step_shell_hooks() {
  commit_staged "${ENV_SNIPPET}${STAGED}" "${ENV_SNIPPET}"
  chown "${DEV_USER}:${DEV_USER}" "${ENV_SNIPPET}"

  if ! grep -qF '.devaloy_env' "${DEV_HOME}/.bashrc" 2>/dev/null; then
    touch "${DEV_HOME}/.bashrc"
    {
      # shellcheck disable=SC2016  # $HOME must stay literal — the dev user's
      # shell expands it at login, not this script.
      printf '%s\n' '[ -f "$HOME/.devaloy_env" ] && . "$HOME/.devaloy_env"'
      cat "${DEV_HOME}/.bashrc"
    } > "${DEV_HOME}/.bashrc.new"
    mv "${DEV_HOME}/.bashrc.new" "${DEV_HOME}/.bashrc"
    chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.bashrc"
  fi

  if ! grep -qF '.devaloy_env' "${DEV_HOME}/.zshenv" 2>/dev/null; then
    # shellcheck disable=SC2016  # as above, $HOME stays literal.
    echo '[ -f "$HOME/.devaloy_env" ] && . "$HOME/.devaloy_env"' >> "${DEV_HOME}/.zshenv"
    chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.zshenv"
  fi
}

# --- retire the old login banner ---
# It printed on every interactive session and earned nothing. Removed from the
# image, and swept out of home volumes created before that change.
step_retire_banner() {
  rm -f "${DEV_HOME}/.devaloy_profile"
  if [ -f "${DEV_HOME}/.bashrc" ] && grep -qF '.devaloy_profile' "${DEV_HOME}/.bashrc"; then
    sed -i '/\.devaloy_profile/d' "${DEV_HOME}/.bashrc"
  fi
}

# --- tokens ---
# Written to a file rather than relied on from the container environment:
# tailscaled spawns login shells itself, and what it forwards from PID 1's
# environment is its business, not a contract. Rewritten from scratch on every
# boot, so clearing a variable in .env and redeploying really does revoke it.
#
# "From scratch" means a staging copy built from nothing, swapped in by
# commit_staged: a value that went away still drops out, and a boot with the
# same values leaves the file untouched. write_secret appends to whatever
# SECRETS_SNIPPET names, so it points at the staging copy for the duration and
# back at the real path before anything else reads it.
step_secrets() {
  SECRETS_FINAL="${SECRETS_SNIPPET}"
  SECRETS_SNIPPET="${SECRETS_FINAL}${STAGED}"
  rm -f "${SECRETS_SNIPPET}"

  write_secret GITHUB_TOKEN "${GITHUB_TOKEN:-}"
  # Authenticates Claude Code with no `/login` from inside the box. The CLI reads
  # this variable itself, so nothing else has to be configured — but note it sits
  # BELOW ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN in Claude Code's precedence
  # order and ABOVE ~/.claude/.credentials.json, so a hand-run `/login` on the box
  # is silently ignored while this is set. It is a static one-year token that
  # never refreshes itself; when it lapses, re-run `claude setup-token` on your
  # laptop and redeploy.
  write_secret CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  # Optional, and only meaningful with WITH_PASEO=true. It goes through this file
  # rather than the container environment for two reasons at once: the Paseo
  # block in entrypoint.sh sources it to hand the daemon its password, and an
  # interactive shell picking it up is what lets `paseo ls` on the box talk to its
  # own daemon with no --host. Note the scope — Paseo's password is DAEMON-wide,
  # not web-UI only, so setting this also makes the phone's direct connection ask
  # for it.
  write_secret PASEO_PASSWORD "${PASEO_PASSWORD:-}"
  # The Infisical machine identity. `infisical login` with no arguments opens a
  # browser and waits on a localhost callback, neither of which exists here, so
  # universal auth is the only route. Nothing is stored at boot: the caller reads these two
  # and runs `infisical login --method=universal-auth --client-id ... --plain
  # --silent` itself, which is why this file is the whole wiring. Same lifecycle
  # as the tokens above: clearing them in .env and redeploying revokes them.
  #
  # Use the `dev` identity here, NEVER `prod`. The `prod` identity can read the
  # production DATABASE_URL, and a production value that reaches an app folder
  # points `pnpm dev` and an e2e database reset at production. Agents run on this
  # box unattended in bypass permission mode; run a production migration or deploy
  # from a laptop instead.
  #
  # Nobody hand-edits ~/.devaloy_secrets. This block deletes and rewrites it on
  # every boot, which is what makes clearing a value in .env a real revocation.
  write_secret INFISICAL_CLIENT_ID "${INFISICAL_CLIENT_ID:-}"
  write_secret INFISICAL_CLIENT_SECRET "${INFISICAL_CLIENT_SECRET:-}"
  # The Cloudflare user API token wrangler and cf read. No CLOUDFLARE_ACCOUNT_ID
  # beside it, on purpose: each project names its account in its wrangler
  # config, and the variable would override that. See docker-compose.yml.
  write_secret CLOUDFLARE_API_TOKEN "${CLOUDFLARE_API_TOKEN:-}"

  SECRETS_SNIPPET="${SECRETS_FINAL}"
  commit_staged "${SECRETS_SNIPPET}${STAGED}" "${SECRETS_SNIPPET}"
}

# --- ntfy push-notification config for hooks ---
# agent-push reads ~/.config/agent-push.env rather than the shell environment,
# because the Paseo daemon and the T3 Code server spawn panes via
# `su -l -s /bin/sh`, which sources neither .zshenv nor .bashrc — so ~/.devaloy_secrets is not reliably in a hook's env.
# Rewritten from scratch every boot (like ~/.devaloy_secrets above), so clearing
# NTFY_TOPIC in .env and redeploying really does turn the feature off. Only
# written when a topic is set; absent, agent-push's own no-topic gate keeps it
# inert. .env's NTFY_* names map onto the script's PUSH_* keys here.
# Built as a staging copy and swapped in by commit_staged, the same way as
# step_secrets and for the same reason.
step_push_config() {
  PUSH_FINAL="${PUSH_ENV_FILE}"
  PUSH_ENV_FILE="${PUSH_FINAL}${STAGED}"
  rm -f "${PUSH_ENV_FILE}"
  if [ -n "${NTFY_TOPIC:-}" ]; then
    push_write PUSH_NTFY_TOPIC "${NTFY_TOPIC}"
    push_write PUSH_NTFY_URL   "${NTFY_SERVER:-}"
    push_write PUSH_NTFY_TOKEN "${NTFY_TOKEN:-}"
    log "ntfy push notifications enabled (topic configured; ~/.config/agent-push.env written)"
  fi
  PUSH_ENV_FILE="${PUSH_FINAL}"
  commit_staged "${PUSH_ENV_FILE}${STAGED}" "${PUSH_ENV_FILE}"
}

# --- managed dotfiles (zsh, Claude Code, Codex) ---
# The repo is the source of truth: every file shipped under config/ is copied
# over its counterpart in /home/dev on each boot, so editing one in the repo
# and redeploying actually changes the box. The copy MERGES rather than
# replaces, so files the repo does not ship — ~/.zshrc.local, credentials,
# session history, skills you added by hand — are left alone.
#
# Three directories under config/ are NOT seeded here, for different reasons.
# config/paseo is a single JSON file that has to be merged key by key rather
# than copied, and the values it needs come from the tailnet, which is not up
# yet at this point in the boot; step_paseo_config (lib/steps/paseo.sh) does it.
# config/docker does not belong in /home/dev at all — dockerd reads
# /etc/docker, so step_docker_config (lib/steps/docker.sh) copies it there
# instead. config/mise is seeded by bootstrap-toolchain.sh, further down,
# because that copy is not a plain copy: it applies the two version pins and
# prunes conf.d to the optional keys that are on, and the script hashes the
# result to decide whether it has anything to install.
#
# The copy goes file by file and skips a file whose bytes already match. A
# plain `cp -R` gave the same content but rewrote every file on every boot, and
# a native re-run has to leave an unchanged home alone (see commit_staged). A
# file that differs is copied with plain `cp`, exactly what `cp -R` did to it:
# an existing file keeps its owner and mode, a new one takes the source mode.
# config/ holds regular files only, no symlinks and no empty directories, so
# walking the files is the whole tree.
seed_config() {
  src="$1"; dest="$2"
  [ -d "${src}" ] || return 0
  # \$f is escaped, so the dev user's shell expands it, not this one.
  as_dev "mkdir -p '${dest}' && cd '${src}' && find . -type f | while IFS= read -r f; do
      cmp -s \"\$f\" '${dest}'/\"\$f\" && continue
      mkdir -p '${dest}'/\"\$(dirname \"\$f\")\" && cp \"\$f\" '${dest}'/\"\$f\" || exit 1
    done"
}

step_seed_config() {
  if [ -d "${CONFIG_SRC}" ]; then
    as_dev "cmp -s '${CONFIG_SRC}/zsh/zshrc' '${DEV_HOME}/.zshrc' ||
      cp -f '${CONFIG_SRC}/zsh/zshrc' '${DEV_HOME}/.zshrc'"
    seed_config "${CONFIG_SRC}/claude" "${DEV_HOME}/.claude"
    seed_config "${CONFIG_SRC}/codex"  "${DEV_HOME}/.codex"
    # Shared agent scripts (agent-push, usage). ~/.local/bin rather than either agent's
    # directory, because both agents run the same script — the hook entries in
    # settings.json and hooks.json both point here. This directory is already on
    # PATH via .devaloy_env, and mise owns it too, so the merge copy matters: a
    # replace would take out mise's own binary.
    seed_config "${CONFIG_SRC}/bin" "${DEV_HOME}/.local/bin"
    # The delete guard was removed: this box is a disposable container, and a
    # PreToolUse prompt on every rm defeats the point of running agents here
    # unattended. Seeding is a merge, so copies from before the removal would
    # otherwise sit on the persistent volume forever, unwired but on PATH.
    as_dev "rm -f '${DEV_HOME}/.local/bin/agent-hook' '${DEV_HOME}/.local/bin/rm-guard'"
    log "Managed dotfiles synced from ${CONFIG_SRC}"
  fi
}

# --- Claude Code onboarding stamp ---
# The token authenticates the CLI, but the interactive TUI gates its first-run
# "Select login method" screen on hasCompletedOnboarding in ~/.claude.json, not
# on auth state — so `claude auth status` reports loggedIn while `claude` still
# asks you to log in. Stamping the flag skips the screen. Only done when the
# token is set: without one, that screen is the way you actually log in.
# ~/.claude.json also holds MCP servers and per-project history, so this merges
# into whatever is there rather than writing the file fresh. A file that
# already carries the flag is left alone, so a re-run does not rewrite it.
step_claude_onboarding() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    CLAUDE_JSON="${DEV_HOME}/.claude.json"
    as_dev "
      if jq -e '.hasCompletedOnboarding == true' '${CLAUDE_JSON}' >/dev/null 2>&1; then
        :
      elif [ -s '${CLAUDE_JSON}' ] && jq -e . '${CLAUDE_JSON}' >/dev/null 2>&1; then
        jq '.hasCompletedOnboarding = true' '${CLAUDE_JSON}' > '${CLAUDE_JSON}.tmp' &&
          mv '${CLAUDE_JSON}.tmp' '${CLAUDE_JSON}'
      else
        printf '%s\n' '{\"hasCompletedOnboarding\": true}' > '${CLAUDE_JSON}'
      fi
    "
    log "Claude Code onboarding marked complete (token auth in use)"
  fi
}
