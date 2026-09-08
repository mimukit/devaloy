#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"
CONFIG_SRC="/opt/devaloy/config"
# Version pins live in bootstrap-toolchain.sh; these are only forwarded, so an
# empty value here falls through to that script's default.

log() { echo "[entrypoint] $*"; }

# Run a command as the dev user under a plain sh. The explicit -s matters now
# that the dev user's login shell is zsh: without it every helper below would
# run through a shell whose startup files this script is in the middle of
# rewriting. -l gives a clean environment and a correct HOME.
as_dev() { su -l -s /bin/sh "${DEV_USER}" -c "$1"; }

# --- shell env: toolchain PATH + OOM reset, for EVERY shell ---
# Written before tailscaled comes up, so the very first session that lands
# already has it. Ubuntu's stock .bashrc bails out early on non-interactive
# shells, so this is sourced from the TOP of .bashrc, above that guard; for zsh
# it hangs off .zshenv, which zsh sources for *every* invocation including
# `ssh devaloy '<cmd>'`. mise shims resolve versions at exec time, so no
# interactive `mise activate` is needed. link-shims covers whatever is left.
ENV_SNIPPET="${DEV_HOME}/.devaloy_env"
cat > "${ENV_SNIPPET}" <<'EOF'
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
export MISE_MINIMUM_RELEASE_AGE=0

# Tokens live in a separate 0600 file so this one stays safe to cat.
[ -f "$HOME/.devaloy_secrets" ] && . "$HOME/.devaloy_secrets"

# The container starts at a negative oom_score_adj (see compose.yml) to keep
# tailscaled off the OOM killer's list. Raise every session back to 0 so a
# runaway build inherits 0 and is killed before the process that keeps you
# connected. Raising is unprivileged; only lowering needs CAP_SYS_RESOURCE.
echo 0 > /proc/self/oom_score_adj 2>/dev/null || true
EOF

# --- browser defaults (only when WITH_BROWSER=true) ---
# Appended after the heredoc above rather than inside it, because that heredoc
# is quoted and this block is conditional. Three defaults, each one correcting
# what `playwright-cli` would otherwise do on this box, read from the source of
# @playwright/cli 0.1.19 (playwright-core 1.63):
#
#   PLAYWRIGHT_MCP_BROWSER=chromium    A bare `playwright-cli open` launches
#                                      Google Chrome, which this image does not
#                                      carry. `chromium` selects the Chrome for
#                                      Testing build the bootstrap downloaded.
#   PLAYWRIGHT_MCP_SANDBOX=true        On Linux, for the bundled Chromium,
#                                      Playwright sets chromiumSandbox=false by
#                                      default and pushes --no-sandbox onto the
#                                      launch. This keeps Chromium's own sandbox
#                                      ON. It works because compose already sets
#                                      seccomp=unconfined for Codex's bubblewrap,
#                                      the same user-namespace permission the
#                                      sandbox needs — the same fact the Orca
#                                      block below relies on.
#   PLAYWRIGHT_MCP_OUTPUT_DIR          A bare `screenshot` writes to
#                                      .playwright-cli/ under the cwd, which is
#                                      a repo in the home volume. /tmp is shared
#                                      with the Paseo daemon in this container,
#                                      so the printed path is what Paseo opens,
#                                      and the files die with the container.
#
# Nothing here needs the libraries or the browser to be present, so it is
# written before the toolchain check rather than after it.
if [ "${WITH_BROWSER:-false}" = "true" ]; then
  cat >> "${ENV_SNIPPET}" <<'EOF'

# Browser capture defaults (WITH_BROWSER=true) — see entrypoint.sh for why each.
export PLAYWRIGHT_MCP_BROWSER=chromium
export PLAYWRIGHT_MCP_SANDBOX=true
export PLAYWRIGHT_MCP_OUTPUT_DIR=/tmp/playwright-cli
EOF
fi
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

# --- retire the old login banner ---
# It printed on every interactive session and earned nothing. Removed from the
# image, and swept out of home volumes created before that change.
rm -f "${DEV_HOME}/.devaloy_profile"
if [ -f "${DEV_HOME}/.bashrc" ] && grep -qF '.devaloy_profile' "${DEV_HOME}/.bashrc"; then
  sed -i '/\.devaloy_profile/d' "${DEV_HOME}/.bashrc"
fi

# --- tokens ---
# Written to a file rather than relied on from the container environment:
# tailscaled spawns login shells itself, and what it forwards from PID 1's
# environment is its business, not a contract. Rewritten from scratch on every
# boot, so clearing a variable in .env and redeploying really does revoke it.
SECRETS_SNIPPET="${DEV_HOME}/.devaloy_secrets"
rm -f "${SECRETS_SNIPPET}"

write_secret() {
  name="$1"; value="$2"
  [ -n "${value}" ] || return 0
  [ -f "${SECRETS_SNIPPET}" ] || \
    install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SECRETS_SNIPPET}"
  # Single-quote the value and escape any embedded quote, so a token with shell
  # metacharacters cannot execute anything when this file is sourced.
  printf "export %s='%s'\n" "${name}" \
    "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")" >> "${SECRETS_SNIPPET}"
  log "${name} wired into the dev shell environment"
}

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
# rather than the container environment for two reasons at once: the Paseo block
# at the bottom sources it to hand the daemon its password, and an interactive
# shell picking it up is what lets `paseo ls` on the box talk to its own daemon
# with no --host. Note the scope — Paseo's password is DAEMON-wide, not web-UI
# only, so setting this also makes the phone's direct connection ask for it.
write_secret PASEO_PASSWORD "${PASEO_PASSWORD:-}"

# --- ntfy push-notification config for hooks ---
# agent-push reads ~/.config/agent-push.env rather than the shell environment,
# because Orca spawns panes via `su -l -s /bin/sh`, which sources neither
# .zshenv nor .bashrc — so ~/.devaloy_secrets is not reliably in a hook's env.
# Rewritten from scratch every boot (like ~/.devaloy_secrets above), so clearing
# NTFY_TOPIC in .env and redeploying really does turn the feature off. Only
# written when a topic is set; absent, agent-push's own no-topic gate keeps it
# inert. .env's NTFY_* names map onto the script's PUSH_* keys here.
PUSH_ENV_FILE="${DEV_HOME}/.config/agent-push.env"
rm -f "${PUSH_ENV_FILE}"
push_write() {
  name="$1"; value="$2"
  [ -n "${value}" ] || return 0
  mkdir -p "${DEV_HOME}/.config"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.config" 2>/dev/null || true
  [ -f "${PUSH_ENV_FILE}" ] || \
    install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${PUSH_ENV_FILE}"
  # Single-quote and escape embedded quotes, so a value with shell
  # metacharacters cannot execute anything when agent-push sources this file.
  printf "%s='%s'\n" "${name}" \
    "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")" >> "${PUSH_ENV_FILE}"
}
if [ -n "${NTFY_TOPIC:-}" ]; then
  push_write PUSH_NTFY_TOPIC "${NTFY_TOPIC}"
  push_write PUSH_NTFY_URL   "${NTFY_SERVER:-}"
  push_write PUSH_NTFY_TOKEN "${NTFY_TOKEN:-}"
  log "ntfy push notifications enabled (topic configured; ~/.config/agent-push.env written)"
fi

# --- managed dotfiles (zsh, Claude Code, Codex) ---
# The repo is the source of truth: every file shipped under config/ is copied
# over its counterpart in /home/dev on each boot, so editing one in the repo
# and redeploying actually changes the box. The copy MERGES rather than
# replaces, so files the repo does not ship — ~/.zshrc.local, credentials,
# session history, skills you added by hand — are left alone.
#
# Two directories under config/ are NOT seeded here, for different reasons.
# config/paseo is a single JSON file that has to be merged key by key rather
# than copied, and the values it needs come from the tailnet, which is not up
# yet at this point in the boot; the Paseo block at the bottom of this file does
# it. config/docker does not belong in /home/dev at all — dockerd reads
# /etc/docker, so the Docker block further down copies it there instead.
seed_config() {
  src="$1"; dest="$2"
  [ -d "${src}" ] || return 0
  as_dev "mkdir -p '${dest}' && cp -R '${src}/.' '${dest}/'"
}
if [ -d "${CONFIG_SRC}" ]; then
  as_dev "cp -f '${CONFIG_SRC}/zsh/zshrc' '${DEV_HOME}/.zshrc'"
  seed_config "${CONFIG_SRC}/claude" "${DEV_HOME}/.claude"
  seed_config "${CONFIG_SRC}/codex"  "${DEV_HOME}/.codex"
  # Shared agent scripts (agent-push). ~/.local/bin rather than either agent's
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

# --- Claude Code onboarding stamp ---
# The token authenticates the CLI, but the interactive TUI gates its first-run
# "Select login method" screen on hasCompletedOnboarding in ~/.claude.json, not
# on auth state — so `claude auth status` reports loggedIn while `claude` still
# asks you to log in. Stamping the flag skips the screen. Only done when the
# token is set: without one, that screen is the way you actually log in.
# ~/.claude.json also holds MCP servers and per-project history, so this merges
# into whatever is there rather than writing the file fresh.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  CLAUDE_JSON="${DEV_HOME}/.claude.json"
  as_dev "
    if [ -s '${CLAUDE_JSON}' ] && jq -e . '${CLAUDE_JSON}' >/dev/null 2>&1; then
      jq '.hasCompletedOnboarding = true' '${CLAUDE_JSON}' > '${CLAUDE_JSON}.tmp' &&
        mv '${CLAUDE_JSON}.tmp' '${CLAUDE_JSON}'
    else
      printf '%s\n' '{\"hasCompletedOnboarding\": true}' > '${CLAUDE_JSON}'
    fi
  "
  log "Claude Code onboarding marked complete (token auth in use)"
fi

# --- tailscaled + Tailscale SSH (started FIRST, before the slow bootstrap) ---
# Ordering matters: the toolchain install takes minutes on a cold volume, and
# there is no sshd fallback any more. Bringing the tailnet up first means the
# box is reachable *during* that window rather than after it.
mkdir -p "${TS_STATE_DIR}" "$(dirname "${TS_SOCKET}")"

log "Starting tailscaled"
tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCKET}" \
  --tun=tailscale0 &
TAILSCALED_PID=$!

for _ in $(seq 1 30); do
  [ -S "${TS_SOCKET}" ] && break
  sleep 1
done
if [ ! -S "${TS_SOCKET}" ]; then
  log "WARNING: tailscaled socket never appeared — check NET_ADMIN and /dev/net/tun."
fi

# --accept-dns defaults to false: letting Tailscale rewrite /etc/resolv.conf in
# a container clobbers Docker's own resolver. Set TS_ACCEPT_DNS=true if you want
# MagicDNS resolution *from* the box.
# --timeout is load-bearing, not defensive: with no authkey and no saved state,
# `tailscale up` prints a login URL and blocks FOREVER. That would wedge the
# entrypoint before the toolchain bootstrap ever runs. Fail instead, and let the
# warning path below tell you how to finish the login by hand.
up_args=(--ssh --timeout=90s --hostname="${TS_HOSTNAME:-devaloy}")
if [ "${TS_ACCEPT_DNS:-false}" = "true" ]; then
  up_args+=(--accept-dns=true)
else
  up_args+=(--accept-dns=false)
fi
# On a redeploy the node identity is already in the state volume, so the authkey
# is optional — only pass it when one is set.
if [ -n "${TS_AUTHKEY:-}" ]; then
  up_args+=(--authkey="${TS_AUTHKEY}")
fi

if tailscale --socket="${TS_SOCKET}" up "${up_args[@]}"; then
  log "Tailscale SSH is up as ${TS_HOSTNAME:-devaloy} ($(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1))"
else
  # Deliberately non-fatal. Restart-looping would not fix a bad authkey or a
  # missing ACL rule, and it would destroy the one diagnostic path left.
  log "WARNING: tailscale up failed — this box is NOT reachable over the tailnet."
  if [ -z "${TS_AUTHKEY:-}" ]; then
    log "WARNING: TS_AUTHKEY is empty. Look further up this log for a"
    log "WARNING: 'To authenticate, visit: ...' URL and open it, or set the key."
  fi
  log "WARNING: recover from the Docker host with:"
  log "WARNING:   docker compose exec devaloy tailscale up --ssh"
fi

# --- nested Docker daemon (only when WITH_DOCKER=true) ---
# A real dockerd, inside this container, so a project's own docker-compose.yml
# starts its stack HERE: bind mounts resolve against /home/dev, published ports
# land in this container's network namespace, and `http://devaloy:3000` reaches
# them over the tailnet. The host socket would give none of that — see the
# WITH_DOCKER block in the Dockerfile for why it is a permanent non-goal.
#
# ORDERING. Read this before moving the block, because it sits between two
# things that both have a claim on it.
#
# It starts AFTER `tailscale up`. dockerd writes iptables rules into the same
# network namespace tailscaled is using, so if the two ever conflict you want to
# find out on a box you can still log into. Bring the tailnet up first and a
# rule clash shows as a broken project stack; start dockerd first and it shows
# as a box that never answers.
#
# It starts BEFORE the mise bootstrap, which is the opposite of Orca and Paseo.
# Those two run last because they shell out through `su -l -s /bin/sh` and need
# link-shims to have put `claude` and `codex` in /usr/local/bin first. dockerd
# needs nothing from mise, so starting it up here lets a cold volume pull
# project images while mise is still installing node.
#
# Nothing below this point waits on Docker. The socket wait is bounded, and a
# daemon that never comes up costs you project stacks and nothing else.
DOCKERD_BIN="/usr/bin/dockerd"
DOCKERD_LOG="/var/log/dockerd.log"
DOCKER_SOCK="/var/run/docker.sock"

if [ "${WITH_DOCKER:-false}" = "true" ]; then
  if [ ! -x "${DOCKERD_BIN}" ]; then
    # The one failure mode worth a loud warning, because the key looks like it
    # was set and nothing happened. WITH_DOCKER is a BUILD argument: it decides
    # what goes into the image, so setting it in the environment alone changes
    # nothing. Same trap as WITH_ORCA, and the opposite of WITH_PASEO.
    log "WARNING: WITH_DOCKER=true but ${DOCKERD_BIN} is not in this image."
    log "WARNING: WITH_DOCKER is a BUILD argument — 'docker compose up -d' cannot"
    log "WARNING: add it. Redeploy with --build, or in Dokploy tick Rebuild."
  else
    # The shipped daemon config. This needs its own copy line: the config sync
    # further up targets /home/dev, and dockerd reads /etc/docker. JSON takes no
    # comments, so what it carries and why is in config/docker/README.md — the
    # short version is that it pins the nested bridge into 10.x, away from the
    # 172.16/12 space the outer host allocates from.
    mkdir -p /etc/docker
    if [ -f "${CONFIG_SRC}/docker/daemon.json" ]; then
      cp "${CONFIG_SRC}/docker/daemon.json" /etc/docker/daemon.json
    else
      log "WARNING: ${CONFIG_SRC}/docker/daemon.json is missing — starting dockerd"
      log "WARNING: on its defaults. Expect a 172.17.0.0/16 bridge, which can"
      log "WARNING: collide with this container's own network."
    fi

    (
      # Explicit, NOT inherited, for the same reason as the Orca block below.
      # The container starts at -500 to keep tailscaled off the OOM killer's
      # list; leaving that inherited would make dockerd exactly as protected as
      # the only route back into the box. The ladder we want is: runaway build
      # (0) dies first, then dockerd and Orca (-250), then tailscaled (-500).
      echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

      # Unbounded restart loop with a sleep, copied from the Orca block. The
      # sleep is what stops a crash-loop spinning hot on a daemon that cannot
      # start at all — a missing runtime, say, which no amount of retrying will
      # fix but which must not also cost you the CPU.
      #
      # Output goes to its own file rather than this log. dockerd is noisy at
      # info level and the entrypoint log is the only view of a `tailscale up`
      # failure; interleaving the two buries the line you need at 3am.
      while true; do
        "${DOCKERD_BIN}" >> "${DOCKERD_LOG}" 2>&1 || true
        echo "[entrypoint] WARNING: dockerd exited — restarting in 10s" >> "${DOCKERD_LOG}"
        sleep 10
      done
    ) &

    # Bounded, and generous: on a working box the socket appears in about a
    # second. Thirty is here to absorb a slow first boot, not to wait out a
    # daemon that is never coming.
    for _ in $(seq 1 30); do
      [ -S "${DOCKER_SOCK}" ] && break
      sleep 1
    done

    if [ -S "${DOCKER_SOCK}" ]; then
      log "Docker daemon ready — logs in ${DOCKERD_LOG}"
      # Anything with a restart policy comes back with the daemon, because
      # /var/lib/docker is a named volume that survives a redeploy. Print the
      # set once, so a stack you started three weeks ago is a line you read on
      # the way in rather than a surprise when a port is already bound.
      _running="$(docker ps --format '{{.Names}} ({{.Image}})' 2>/dev/null || true)"
      if [ -n "${_running}" ]; then
        log "Nested containers restarted with the daemon:"
        printf '%s\n' "${_running}" | while IFS= read -r _line; do
          log "  ${_line}"
        done
      fi
      unset _running
    else
      # The other failure mode: the engine is in the image and the daemon still
      # will not start. That is almost always the container lacking authority
      # over its own namespaces, which is what the two runtime keys grant.
      log "WARNING: dockerd did not come up within 30s — project stacks will not run."
      log "WARNING: this container needs authority over its own namespaces. Set"
      log "WARNING: DEVALOY_RUNTIME=sysbox-runc (shared host) or"
      log "WARNING: DEVALOY_PRIVILEGED=true (a host you own alone), then redeploy."
      log "WARNING: the daemon's own reason is at the end of ${DOCKERD_LOG}."
    fi
  fi
fi

# --- mise bootstrap + pinned toolchain (runs as dev) ---
# The skip-if-already-installed decision lives in bootstrap-toolchain.sh, not
# here: it is gated on that script's TOOLSET_REVISION, and only the script knows
# what revision it ships. Keeping the check next to the tool list is what stops
# a newly added tool from being skipped forever on a volume that was
# provisioned before it existed.
#
# Deliberately NOT fatal: a network blip on first boot must not take the box
# down. The revision marker is only written on success, so a later boot (or
# `devaloy-update`) retries cleanly.
#
# Only forward a MISE_<TOOL>_VERSION whose <TOOL> is a real mise registry entry.
# mise reads every one of these out of its own environment as a tool
# declaration, so forwarding one for a tool it does not know makes every mise
# call in the child fail. That is what a MISE_PASEO_VERSION did here: Paseo
# ships as npm:@getpaseo/cli and there is no `paseo` in the registry, so the
# bootstrap died at `mise use` and never wrote its marker. `node` and `herdr`
# are registry entries, which is why those two are safe. Paseo now tracks latest
# with no variable at all — see the comment in bootstrap-toolchain.sh.
# WITH_BROWSER is the one key here that is ALSO a build argument. The bootstrap
# below installs the CLI and the browser into the home volume on this key alone,
# but Chromium cannot start without the libraries the Dockerfile block puts in
# the image — so a box that set the key without --build gets a working
# `playwright-cli` and a browser that dies on a missing .so. Same trap as
# WITH_DOCKER, and warned about the same way. libnss3 is the probe because it is
# the first library Chromium loads and it is in no other block of the image.
if [ "${WITH_BROWSER:-false}" = "true" ] && ! dpkg -s libnss3 >/dev/null 2>&1; then
  log "WARNING: WITH_BROWSER=true but the Chromium libraries are not in this image."
  log "WARNING: WITH_BROWSER is also a BUILD argument — 'docker compose up -d' cannot"
  log "WARNING: add them. Redeploy with --build, or in Dokploy tick Rebuild."
fi

log "Checking the mise toolchain"
if as_dev "MISE_NODE_VERSION='${MISE_NODE_VERSION:-}' \
    MISE_HERDR_VERSION='${MISE_HERDR_VERSION:-}' \
    WITH_PASEO='${WITH_PASEO:-false}' \
    WITH_BROWSER='${WITH_BROWSER:-false}' \
    /usr/local/bin/bootstrap-toolchain.sh"; then
  log "Toolchain ready"
else
  log "WARNING: toolchain bootstrap failed — the box is still reachable."
  log "WARNING: once you are in, re-run it with: devaloy-update"
fi

# Make the toolchain resolvable from sessions that never source .bashrc.
DEV_HOME="${DEV_HOME}" /usr/local/bin/link-shims || \
  log "WARNING: link-shims failed — non-interactive commands may not find the toolchain."

# --- gh and git over HTTPS via GITHUB_TOKEN ---
# Run after link-shims because that is what puts gh on root's PATH.
#
# gh's credential is stored on disk rather than left to the environment, and
# that is the whole point of this block. gh does read GITHUB_TOKEN by itself,
# but only from a process that HAS it — and the token deliberately lives in
# ~/.devaloy_secrets (see the tokens block above), which nothing sources except
# .zshenv and .bashrc. Orca's headless server is started through
# `su -l -s /bin/sh`, which reads neither and which clears the environment it
# inherited from PID 1, so every `gh` that server shells out for — the mobile
# app's repo, branch, PR and issue pickers — came back with "To get started with
# GitHub CLI, please run: gh auth login" while an interactive terminal on the
# same box worked fine. Storing it takes the environment out of the loop for
# every consumer at once, instead of teaching each one to source the file.
#
# hosts.yml is rebuilt from scratch on every boot, exactly like
# ~/.devaloy_secrets — removed here unconditionally, ABOVE the token check, so
# clearing GITHUB_TOKEN in .env and redeploying genuinely revokes gh's access
# rather than leaving a working credential behind in the home volume.
rm -f "${DEV_HOME}/.config/gh/hosts.yml"

if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
  # The token is read from the 0600 file and piped on stdin, never passed as an
  # argument, where it would be readable in /proc for the life of the call.
  # GITHUB_TOKEN has to be unset around the call itself: gh refuses to write
  # hosts.yml while an environment token is set, on the grounds that the
  # environment would outrank the stored credential anyway.
  # shellcheck disable=SC2016  # $HOME and $GITHUB_TOKEN belong to the dev shell.
  if as_dev '. "$HOME/.devaloy_secrets"; _t="$GITHUB_TOKEN"; unset GITHUB_TOKEN GH_TOKEN; printf "%s" "$_t" | gh auth login --with-token' 2>/dev/null; then
    log "gh authenticated to GitHub (credential stored, not environment-bound)"
  else
    log "WARNING: gh auth login failed — the Orca app's GitHub pickers, and any"
    log "WARNING: other gh call from outside a login shell, will report that you"
    log "WARNING: must run 'gh auth login' first."
  fi

  # Teaches git to ask gh for credentials, so `git push` works without a second
  # login. The helper it installs re-invokes gh, which is why this runs after
  # the login above — with hosts.yml in place the helper answers from any
  # process, including one Orca spawned, rather than only from a login shell.
  # Still sources the secrets itself so that a failed login above costs the
  # pickers but not `git push`, which the environment token alone can carry.
  # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
  if as_dev '. "$HOME/.devaloy_secrets" && gh auth setup-git' 2>/dev/null; then
    log "git configured to authenticate to GitHub through gh"
  else
    log "WARNING: gh auth setup-git failed — 'git push' over HTTPS may prompt."
  fi
fi

# --- git identity ---
# Without this every commit from the box dies with "Author identity unknown",
# which an unattended agent cannot recover from. Written with `git config
# --global`, one key at a time, rather than by templating ~/.gitconfig: the file
# lives in the home volume and may hold aliases, diff tools and other settings
# added by hand, and only the keys below are ours to own.
#
# Runs after the gh block on purpose — the fallback path shells out to gh.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
git_cfg() { as_dev "git config --global $(sq "$1") $(sq "$2")"; }

GIT_NAME="${GIT_AUTHOR_NAME:-}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-}"

# Fallback: ask GitHub who the token belongs to. The address is the account's
# ID+login noreply form rather than .email, because .email is null unless the
# profile email is public, and the noreply address is ALWAYS a verified address
# on the account — which is what GitHub requires before it will mark a signed
# commit as Verified.
if { [ -z "${GIT_NAME}" ] || [ -z "${GIT_EMAIL}" ]; } &&
   [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
  # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
  GH_USER_JSON="$(as_dev '. "$HOME/.devaloy_secrets" && gh api user' 2>/dev/null || true)"
  if [ -n "${GH_USER_JSON}" ]; then
    # `|| true` inside each substitution, not after: gh can hand back a body
    # that is not the object jq expects, and a bare jq failure would take the
    # whole entrypoint down under `set -e` before tailscaled is even waited on.
    [ -n "${GIT_NAME}" ] || GIT_NAME="$(printf '%s' "${GH_USER_JSON}" |
      jq -r '.name // .login // empty' 2>/dev/null || true)"
    [ -n "${GIT_EMAIL}" ] || GIT_EMAIL="$(printf '%s' "${GH_USER_JSON}" |
      jq -r 'select(.id and .login) | "\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null || true)"
  fi
fi

if [ -n "${GIT_NAME}" ] && [ -n "${GIT_EMAIL}" ]; then
  git_cfg user.name  "${GIT_NAME}"
  git_cfg user.email "${GIT_EMAIL}"
  log "git identity set to ${GIT_NAME} <${GIT_EMAIL}>"
else
  log "WARNING: no git identity — commits from this box will fail with"
  log "WARNING: 'Author identity unknown'. Set GIT_AUTHOR_NAME and"
  log "WARNING: GIT_AUTHOR_EMAIL in .env, or supply a GITHUB_TOKEN."
fi

# --- SSH-signed commits ---
# GitHub shows a commit as Unverified unless it carries a signature from a key
# registered on the account. SSH signing rather than GPG: one key file, no
# gpg-agent, no passphrase daemon to keep alive in a container.
#
# Rebuilt from scratch on every boot, exactly like ~/.devaloy_secrets — clearing
# GIT_SIGNING_SSH_KEY in .env and redeploying really does remove the key AND
# turn commit.gpgsign back off, so a later commit does not fail on a key that is
# no longer there.
SIGNING_KEY="${DEV_HOME}/.ssh/devaloy_signing"
ALLOWED_SIGNERS="${DEV_HOME}/.config/git/allowed_signers"
rm -f "${SIGNING_KEY}" "${SIGNING_KEY}.pub" "${ALLOWED_SIGNERS}"

if [ -n "${GIT_SIGNING_SSH_KEY:-}" ]; then
  # Accepts the key either base64-encoded on one line (the documented form —
  # a .env value cannot portably hold the newlines a PEM block needs) or as
  # literal PEM, for the case where it arrives through some other channel.
  KEY_MATERIAL="${GIT_SIGNING_SSH_KEY}"
  case "${KEY_MATERIAL}" in
    *"PRIVATE KEY"*) ;;
    *) KEY_MATERIAL="$(printf '%s' "${KEY_MATERIAL}" | tr -d ' \n' | base64 -d 2>/dev/null || true)" ;;
  esac

  case "${KEY_MATERIAL}" in
    *"PRIVATE KEY"*)
      as_dev "mkdir -p '${DEV_HOME}/.ssh' && chmod 700 '${DEV_HOME}/.ssh'"
      install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SIGNING_KEY}"
      # Exactly one trailing newline: OpenSSH rejects a private key without it,
      # and command substitution above already ate any that were there.
      printf '%s\n' "${KEY_MATERIAL}" > "${SIGNING_KEY}"

      # -P '' and </dev/null together are what stop this hanging forever on a
      # passphrase prompt: an encrypted key fails fast here instead, which is
      # the right outcome — nothing in this container can type a passphrase.
      if as_dev "ssh-keygen -y -P '' -f '${SIGNING_KEY}' > '${SIGNING_KEY}.pub'" </dev/null 2>/dev/null &&
         [ -s "${SIGNING_KEY}.pub" ]; then
        git_cfg gpg.format ssh
        # The PRIVATE key path, not the .pub: git hands this straight to
        # `ssh-keygen -Y sign -f`, which needs the secret half and finds the
        # public one beside it.
        git_cfg user.signingkey "${SIGNING_KEY}"
        git_cfg commit.gpgsign true
        # Tags too — GitHub verifies those on the release page as well.
        git_cfg tag.gpgsign true

        # Only affects local `git log --show-signature` output, which without it
        # reports every one of your own commits as from an unknown signer.
        # GitHub does not read this file; it checks the key on your account.
        as_dev "mkdir -p '$(dirname "${ALLOWED_SIGNERS}")'"
        install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${ALLOWED_SIGNERS}"
        printf '%s %s\n' "${GIT_EMAIL:-dev}" "$(cat "${SIGNING_KEY}.pub")" > "${ALLOWED_SIGNERS}"
        git_cfg gpg.ssh.allowedSignersFile "${ALLOWED_SIGNERS}"

        log "commits will be SSH-signed with $(ssh-keygen -lf "${SIGNING_KEY}.pub" 2>/dev/null | awk '{print $2}')"

        # --- register the public half on GitHub as a signing key ---
        # This is what turns the badge from Unverified to Verified, and it is
        # not optional or inferrable: GitHub checks the signature against the
        # keys listed under SSH *signing* keys on the account. A key you already
        # use for authentication does not count, even byte-for-byte identical —
        # it has to be listed under both types. Doing it here means bringing
        # your existing key needs nothing done on github.com.
        #
        # Best-effort on purpose. It needs admin:ssh_signing_key on the PAT
        # (fine-grained: "SSH signing keys" read+write), which a token minted for
        # `git push` will not have. Every failure path prints the manual step and
        # boots on rather than holding the box hostage to a scope.
        if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
          # Match on the key body alone, never the whole line: the comment field
          # differs between the copy on your laptop and the one ssh-keygen -y
          # regenerates here, so comparing lines would re-upload every boot.
          PUB_BODY="$(awk '{print $2}' "${SIGNING_KEY}.pub")"
          # No --paginate: one page of 100 is far past anyone's signing-key count,
          # and paginating an array endpoint hands jq concatenated arrays.
          # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
          SIGNING_KEYS_JSON="$(as_dev '. "$HOME/.devaloy_secrets" && gh api "/user/ssh_signing_keys?per_page=100"' 2>/dev/null || true)"

          if printf '%s' "${SIGNING_KEYS_JSON}" | jq -e --arg k "${PUB_BODY}" \
               'any(.[]; (.key | split(" ")[1]) == $k)' >/dev/null 2>&1; then
            log "signing key is already registered on GitHub"
          else
            # shellcheck disable=SC2016  # as above.
            ADD_CMD='. "$HOME/.devaloy_secrets" && gh api --method POST /user/ssh_signing_keys'
            ADD_CMD="${ADD_CMD} -f title=$(sq "devaloy (${TS_HOSTNAME:-devaloy})")"
            ADD_CMD="${ADD_CMD} -f key=$(sq "$(cat "${SIGNING_KEY}.pub")")"
            ADD_OUT="$(as_dev "${ADD_CMD}" 2>&1 || true)"
            case "${ADD_OUT}" in
              # Also the path taken when the token can write but not read, so the
              # listing above came back empty and this POST was a no-op.
              *'already in use'*|*'already exists'*)
                log "signing key is already registered on GitHub" ;;
              *'"id"'*)
                log "registered the signing key on GitHub — commits will show as Verified" ;;
              *)
                log "WARNING: could not register the signing key on GitHub."
                log "WARNING: add ~/.ssh/devaloy_signing.pub by hand at"
                log "WARNING:   https://github.com/settings/ssh/new  (type: Signing Key)"
                log "WARNING: or give the PAT the admin:ssh_signing_key scope to"
                log "WARNING: let this happen on its own. Commits are signed either"
                log "WARNING: way; GitHub just shows them Unverified until it is done." ;;
            esac
          fi
        else
          log "GitHub marks these Verified only once the matching PUBLIC key is"
          log "added to your account as a SIGNING key (not an authentication key):"
          log "  https://github.com/settings/ssh/new"
        fi
      else
        rm -f "${SIGNING_KEY}" "${SIGNING_KEY}.pub"
        log "WARNING: GIT_SIGNING_SSH_KEY is not a usable key — commits stay unsigned."
        log "WARNING: it must be an OpenSSH private key with NO passphrase."
      fi
      ;;
    *)
      log "WARNING: GIT_SIGNING_SSH_KEY did not decode to an SSH private key."
      log "WARNING: expected base64 of the key file — commits stay unsigned."
      ;;
  esac
fi

# Reached both when no key is configured and when one failed to install, so a
# box that signed yesterday does not fail every commit today.
git_unset() { as_dev "git config --global --unset-all $(sq "$1") || true"; }
if [ ! -s "${SIGNING_KEY}" ]; then
  git_unset commit.gpgsign
  git_unset tag.gpgsign
  git_unset user.signingkey
  git_unset gpg.format
  git_unset gpg.ssh.allowedSignersFile
fi

# --- clone the repos named in DEVALOY_REPOS ---
# Seeds ~/projects on a fresh box so the first session lands on real code
# instead of an empty home. The list lives in .env, which is gitignored, so no
# repository of yours is ever named in this repository.
#
# Runs LAST of the git blocks on purpose: it clones over HTTPS and relies on the
# credential helper that `gh auth setup-git` installed above. Without a
# GITHUB_TOKEN the public repos in the list still clone and the private ones
# fail one by one, which is the right split.
#
# Every failure here is a warning, never an exit. This block is far below
# tailscaled, and a typo in one URL must not cost you the SSH you would fix it
# from. `set -e` is on, hence the `if !` around the clone rather than a bare
# call, which would take the whole script down on the first bad URL.
if [ -n "${DEVALOY_REPOS:-}" ]; then
  PROJECTS_DIR="${DEV_HOME}/projects"
  as_dev "mkdir -p $(sq "${PROJECTS_DIR}")"

  # Word-split on the default IFS, so spaces, tabs and newlines all separate.
  # `set -f` is what makes that safe: a `?` or `*` anywhere in a URL would
  # otherwise glob against the filesystem and expand into something else
  # entirely. Restored right after, because the rest of this script does not
  # expect noglob. The split lands in the positional parameters, which this
  # script never reads — it takes no arguments.
  set -f
  # shellcheck disable=SC2086  # the split is the point; see the note above.
  set -- ${DEVALOY_REPOS}
  set +f

  for spec in "$@"; do
    # Whitelist, not a blacklist. Every clone below reaches git through
    # `as_dev`, which is `su -c` on ONE string, so a token holding a quote or a
    # semicolon is a command injection with root's environment behind it. The
    # sq() quoting further down is the second layer; this is the first.
    case "${spec}" in
      *[!A-Za-z0-9._:/@+~-]*)
        log "WARNING: DEVALOY_REPOS entry '${spec}' has an illegal character — skipped."
        continue
        ;;
    esac

    # Three accepted forms, matched in order. The shorthand needs exactly one
    # slash and no colon, which is what tells `owner/repo` apart from the SSH
    # form `git@github.com:owner/repo`.
    case "${spec}" in
      https://*|http://*|git@*:*)
        repo_url="${spec}"
        ;;
      */*/*|*:*)
        log "WARNING: DEVALOY_REPOS entry '${spec}' is not a URL or owner/repo — skipped."
        continue
        ;;
      */*)
        repo_url="https://github.com/${spec}"
        ;;
      *)
        log "WARNING: DEVALOY_REPOS entry '${spec}' is not a URL or owner/repo — skipped."
        continue
        ;;
    esac

    # Normalize before taking the basename, so github.com/foo/bar/,
    # github.com/foo/bar and github.com/foo/bar.git all land in ~/projects/bar.
    repo_url="${repo_url%/}"
    repo_name="${repo_url##*/}"
    repo_name="${repo_name##*:}"
    repo_name="${repo_name%.git}"
    if [ -z "${repo_name}" ]; then
      log "WARNING: DEVALOY_REPOS entry '${spec}' names no repository — skipped."
      continue
    fi

    repo_dir="${PROJECTS_DIR}/${repo_name}"
    # Already cloned: silent. This block runs on EVERY boot, and a redeploy of a
    # box with fifteen repos should not print fifteen lines saying so.
    if [ -d "${repo_dir}/.git" ]; then
      continue
    fi
    # Occupied by something that is not a clone. Two repos of the same name from
    # different owners land here, and so does a directory you made by hand.
    # Skipped rather than merged into, because the alternative writes into your
    # work.
    if [ -e "${repo_dir}" ]; then
      log "WARNING: ~/projects/${repo_name} exists and is not a git clone —"
      log "WARNING: '${spec}' skipped. Rename or remove it, then restart."
      continue
    fi

    log "Cloning ${spec} into ~/projects/${repo_name}"
    if ! as_dev "git clone --quiet $(sq "${repo_url}") $(sq "${repo_dir}")" 2>&1; then
      # A half-written directory would be read as "occupied" on the next boot
      # and never retried, so the failed attempt is cleared here.
      rm -rf "${repo_dir}"
      log "WARNING: clone of '${spec}' failed — a private repo needs GITHUB_TOKEN."
    fi
  done
  unset spec repo_url repo_name repo_dir
fi

# --- Orca headless runtime (only present when built with WITH_ORCA=true) ---
# Lets the Orca desktop and mobile apps talk to this box, which Tailscale SSH
# alone cannot do — they speak to a runtime, not a terminal.
#
# Silence is correct when the binary is absent: WITH_ORCA=false is the DEFAULT
# build, so a missing /usr/bin/orca-ide is the normal case and not a fault. Do
# not "improve" this into a warning — every stock box would nag about a package
# it was never asked to install.
#
# Runs after link-shims on purpose: Orca shells out to `codex` and `claude`, and
# `su -l -s /bin/sh` does NOT get the mise shims on PATH — only /usr/local/bin,
# which is exactly what link-shims mirrors them into. Start this any earlier and
# agents launched from an Orca client die with `spawn codex ENOENT`.
ORCA_BIN="/usr/bin/orca-ide"
ORCA_PORT=6768

if [ -x "${ORCA_BIN}" ]; then
  ORCA_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
  if [ -n "${ORCA_IP}" ]; then
    (
      # Explicit, NOT inherited — and the value is deliberate. The container
      # starts at -500 to keep tailscaled off the OOM killer's list, and
      # oom_score_adj is inherited by children, so leaving this alone would make
      # Orca exactly as protected as the daemon that is your only way back in.
      # Interactive shells raise themselves to 0 (see .devaloy_env above), so
      # the ordering we want is: runaway build (0) dies first, then Orca (-250),
      # and tailscaled (-500) last. Raising above an inherited value is
      # unprivileged, so this needs no CAP_SYS_RESOURCE.
      echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

      # Unbounded restart loop: there is no runtime kill switch by design, and
      # the sleep is what stops a crash-loop spinning hot. To actually stop it,
      # `docker compose stop` or rebuild with WITH_ORCA=false — see the README.
      #
      # xvfb-run because Electron wants an X display even headless; the sandbox
      # is KEPT (never --no-sandbox) and works because compose already sets
      # seccomp=unconfined for Codex's bubblewrap, which is the same user
      # namespace permission Chromium's sandbox needs.
      # SHELL is set explicitly because as_dev runs `su -l -s /bin/sh`, and su
      # exports whatever it was given with -s. Orca spawns its terminals from
      # $SHELL rather than /etc/passwd, so without this every terminal opened
      # from the desktop or mobile app lands in sh instead of the dev user's
      # actual login shell. The -s /bin/sh itself has to stay — see as_dev.
      while true; do
        as_dev "SHELL=/usr/bin/zsh LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a '${ORCA_BIN}' serve \
          --port '${ORCA_PORT}' --pairing-address '${ORCA_IP}'" || true
        log "WARNING: orca serve exited — restarting in 10s"
        sleep 10
      done
    ) &
    # Both the desktop and the phone pair off this one server's own output —
    # there is no second command to run. A second `orca serve` in this container
    # hits Electron's single-instance lock and exits, and there is no `orca
    # pair` subcommand. --mobile-pairing is a flag on THIS launch that swaps the
    # code for a mobile-scoped one; adding it here costs the desktop's default
    # link, which is why it is not here.
    log "Orca server on ${ORCA_IP}:${ORCA_PORT} — pair both the desktop and the"
    log "phone from this server's own log: the 'Pairing URL' line for the"
    log "desktop, and the orca:// link or 'Web client URL' line for the phone."
  else
    # Same call as tailscale up's own failure path: an advertised address that
    # nothing can route to is worse than no server at all, because the client
    # fails at pairing time rather than here where the log explains why.
    log "WARNING: no tailnet IPv4 — not starting orca serve."
    log "WARNING: fix the tailscale failure above, then restart the container."
  fi
fi

# --- Paseo daemon (only when WITH_PASEO=true) ---
# The second remote runtime, next to Orca above and answering the same want: the
# Paseo phone, desktop, browser and CLI clients speak to a daemon, not a
# terminal. Everything else about the box is unchanged.
#
# Read the differences from the Orca block before editing this one — they are
# deliberate, not drift:
#
#   * The KEY IS A RUNTIME VARIABLE, not a build arg. Paseo is a plain npm
#     package installed into the home volume by bootstrap-toolchain.sh, so there
#     is no image payload to gate and `docker compose up -d` is enough to flip
#     it. WITH_ORCA needs --build; this does not.
#   * A MISSING BINARY IS A FAULT HERE, and warns. A missing orca-ide is the
#     default build and so is silent. A missing paseo when the key is on means
#     the bootstrap failed, and the log should say so.
#   * IT BINDS THE TAILNET ADDRESS, not 0.0.0.0. Paseo takes a bind address
#     (orca serve does not), and its own default is 127.0.0.1, so this widens
#     it exactly as far as the tailnet and no further. Nothing lands on the
#     docker bridge, unlike Orca's 6768.
#   * IT IS CONFIGURED BY FILE, not by flags. Orca serve takes its settings on
#     the command line and nothing else reads them. Paseo has a config file that
#     every other `paseo` on the box reads too, so the settings live there. See
#     the config block below.
#
# Runs after link-shims for the same reason Orca does: the daemon shells out to
# `claude` and `codex`, and `su -l -s /bin/sh` gets /usr/local/bin but not mise's
# shim directory.
PASEO_PORT=6767

if [ "${WITH_PASEO:-false}" = "true" ]; then
  if as_dev "command -v paseo >/dev/null 2>&1"; then
    PASEO_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
    if [ -n "${PASEO_IP}" ]; then
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
          log "WARNING: .env and redeploy, or turn the web UI back off."
        fi
      fi

      # --- the daemon's config file (~/.paseo/config.json) ---
      # The daemon would start from flags alone. Everything ELSE on the box
      # would not: `paseo ls` over SSH, `paseo daemon restart` after you change
      # something, and the MCP endpoint all read this file to find the daemon,
      # and Paseo's own default is 127.0.0.1:6767. Flags fix the one process
      # started here and leave every other caller talking to nothing. So the
      # settings live in the file and the start command below carries none.
      #
      # The tailnet address is the reason this is written at boot rather than
      # shipped: the IP is assigned by the tailnet and is not knowable at build
      # time. It also runs HERE rather than in the managed-dotfiles block near
      # the top of this file, which is where every other config/ directory is
      # seeded, because it needs PASEO_IP and `tailscale up` has not run yet up
      # there.
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
      # the start command below sources. daemon.auth.password takes a bcrypt
      # hash and nothing else; the environment variable takes the plaintext and
      # the daemon hashes it at startup. Writing the plaintext here would fail
      # the schema, and hashing it here would put a credential in a file the
      # app rewrites.
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
      # Paseo block is non-fatal by design — the same reason the Orca block
      # warns rather than exits — and aborting here would stop a container that
      # is otherwise up and reachable over SSH.
      PASEO_START_ARGS=""
      mkdir -p "${DEV_HOME}/.paseo" 2>/dev/null || true
      chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.paseo" 2>/dev/null || true
      if [ -n "${PASEO_MERGED}" ] &&
         printf '%s\n' "${PASEO_MERGED}" | jq . > "${PASEO_CONFIG}.tmp" 2>/dev/null &&
         mv "${PASEO_CONFIG}.tmp" "${PASEO_CONFIG}"; then
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
        PASEO_START_ARGS="--no-relay --listen '${PASEO_IP}:${PASEO_PORT}'"
        if [ "${PASEO_WEB_UI}" = "true" ]; then
          PASEO_START_ARGS="${PASEO_START_ARGS} --web-ui --hostnames '${TS_HOSTNAME:-devaloy},.ts.net'"
        fi
      fi

      (
        # Explicit, NOT inherited — see the identical note in the Orca block.
        # The container starts at -500 to keep tailscaled off the OOM killer's
        # list, so an untouched daemon would be as protected as the only process
        # that keeps you connected. -250 sits above a runaway build and below
        # tailscaled.
        echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

        # A SECOND supervision layer, on purpose. `paseo daemon start
        # --foreground` execs Paseo's own supervisor, which restarts its worker
        # on crash and holds a PID lock under ~/.paseo. Nothing but this loop
        # restarts the supervisor itself, and it costs nothing while the inner
        # layer is doing its job. --foreground is also what keeps the daemon's
        # output in `docker compose logs`: without it Paseo detaches and writes
        # to a file, and the container log is the recovery surface when the
        # tailnet is down.
        #
        # Sourcing the secrets file is load-bearing and not decoration. Agents
        # the daemon spawns inherit ITS environment, and as_dev runs
        # `su -l -s /bin/sh`, which reads neither .zshenv nor .bashrc — so
        # without this line CLAUDE_CODE_OAUTH_TOKEN never reaches a Claude Code
        # session started from the phone, and it falls back to a credentials
        # file a token-provisioned box does not have. Same trap the gh block
        # above exists to work around. It also carries PASEO_PASSWORD to the
        # daemon.
        #
        # The `if [ -f ]` guard is NOT belt-and-braces, and `. file || true` is
        # not a substitute for it. write_secret only creates that file when at
        # least one secret is set, so a box with no tokens and no password does
        # not have one — and as_dev runs `su -l -s /bin/sh`, which is dash here.
        # `.` is a POSIX special builtin, so in dash a missing file exits the
        # whole shell BEFORE the `||` is ever considered. Written the other way,
        # such a box never starts the daemon and this loop warns every 10s
        # forever.
        #
        # PASEO_START_ARGS is EMPTY on a healthy boot. The listen address, the
        # relay switch, the web UI and the hostnames all come from
        # ~/.paseo/config.json, so a `paseo daemon restart` you run over SSH
        # brings the daemon back exactly as this line starts it. The variable
        # only fills in when the config write above failed.
        #
        # SHELL is exported for the same reason the Orca block sets it: su
        # exports whatever it was given with -s, so as_dev hands the daemon
        # SHELL=/bin/sh. Paseo opens a terminal from `env.SHELL || "/bin/sh"`
        # and never reads /etc/passwd, so without this line every pane from
        # cmd+t in the app lands in sh instead of the dev user's login shell.
        # There is no shell key in ~/.paseo/config.json, so this cannot move to
        # the config block above. It is EXPORTED rather than written as a
        # command prefix because the `if` that follows is a compound command,
        # which takes no assignment prefix. The -s /bin/sh itself has to stay —
        # see as_dev.
        while true; do
          as_dev "export SHELL=/usr/bin/zsh; \
            if [ -f '${SECRETS_SNIPPET}' ]; then . '${SECRETS_SNIPPET}'; fi; \
            paseo daemon start --foreground ${PASEO_START_ARGS}" || true
          log "WARNING: the Paseo daemon exited — restarting in 10s"
          sleep 10
        done
      ) &
      log "Paseo daemon on ${PASEO_IP}:${PASEO_PORT} — add it in the app under"
      log "Settings > Add host > Direct connection, with SSL off. The relay is"
      log "deliberately disabled, so the phone needs Tailscale connected."

      # --- install the plugins named in PASEO_PLUGINS ---
      # Plugins are the one part of the Paseo setup that config/paseo/config.json
      # cannot carry. The config file records a plugin AFTER it is installed, and
      # a git-sourced plugin also needs its clone under ~/.paseo/plugins, which
      # only `paseo plugin install` creates. So this drives the CLI rather than
      # writing the key.
      #
      # It runs in the BACKGROUND and after the daemon loop above, because
      # `paseo plugin install` talks to the daemon and the daemon is not up yet
      # on the line below. Running it in the foreground would hold the entrypoint
      # short of the `wait` at the bottom of this file for as long as the daemon
      # takes to answer, and a daemon that never answers would cost you the SSH
      # you would fix it from.
      if [ -n "${PASEO_PLUGINS:-}" ]; then
        (
          # Every CLI call below has to carry the SAME environment the daemon
          # loop above starts the daemon with, and PASEO_PASSWORD is the reason.
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
            log "WARNING: <source>', or restart the container."
            exit 0
          fi

          # Same split as DEVALOY_REPOS, for the same reason — see the long note
          # on `set -f` there.
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
        ) &
      fi
    else
      # Same call as the Orca block and as tailscale up's own failure path: a
      # daemon on an address nothing can route to fails at connect time rather
      # than here, where the log can still explain why.
      log "WARNING: no tailnet IPv4 — not starting the Paseo daemon."
      log "WARNING: fix the tailscale failure above, then restart the container."
    fi
  else
    log "WARNING: WITH_PASEO is true but paseo is not installed. The toolchain"
    log "WARNING: bootstrap above did not finish — once you are in, re-run it"
    log "WARNING: with: devaloy-update"
  fi
fi

log "devaloy is up. Connect with: ssh dev@${TS_HOSTNAME:-devaloy}"
wait "${TAILSCALED_PID}"
