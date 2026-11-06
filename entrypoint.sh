#!/usr/bin/env bash
set -euo pipefail

# The per-boot setup lives in lib/steps/ as functions, one per section, so a
# second caller can run the same steps without a second copy of the logic.
# What stays here is the order they run in and the process starts that only
# make sense inside this container: tailscaled, the dockerd restart loop, the
# Paseo daemon loop, the T3 Code server loop and the final `wait`.
#
# The ORDER below is load-bearing. Each step's comment says what it needs
# before it, and several read globals an earlier step set. Read those before
# moving a call.
#
# The Dockerfile copies lib/ to /usr/local/lib/devaloy, so the steps land in
# /usr/local/lib/devaloy/steps. DEVALOY_LIB is overridable the same way the
# devaloy CLI allows, which is how to source a git checkout instead.
DEVALOY_LIB="${DEVALOY_LIB:-/usr/local/lib/devaloy}"
# shellcheck source=lib/steps/common.sh
. "${DEVALOY_LIB}/steps/common.sh"
# shellcheck source=lib/steps/env.sh
. "${DEVALOY_LIB}/steps/env.sh"
# shellcheck source=lib/steps/tailscale.sh
. "${DEVALOY_LIB}/steps/tailscale.sh"
# shellcheck source=lib/steps/docker.sh
. "${DEVALOY_LIB}/steps/docker.sh"
# shellcheck source=lib/steps/toolchain.sh
. "${DEVALOY_LIB}/steps/toolchain.sh"
# shellcheck source=lib/steps/git.sh
. "${DEVALOY_LIB}/steps/git.sh"
# shellcheck source=lib/steps/paseo.sh
. "${DEVALOY_LIB}/steps/paseo.sh"
# shellcheck source=lib/steps/t3code.sh
. "${DEVALOY_LIB}/steps/t3code.sh"

# --- the dev shell, secrets and dotfiles (before tailscaled) ---
step_shell_env
step_browser_env
step_shell_hooks
step_retire_banner
step_secrets
step_push_config
step_seed_config
step_claude_onboarding

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

step_tailscale_up

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
# It starts BEFORE the mise bootstrap, which is the opposite of Paseo and T3
# Code. Those two run last because they shell out through `su -l -s /bin/sh` and need
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
    # nothing. The opposite of WITH_PASEO, which is a runtime variable.
    log "WARNING: WITH_DOCKER=true but ${DOCKERD_BIN} is not in this image."
    log "WARNING: WITH_DOCKER is a BUILD argument — 'docker compose up -d' cannot"
    log "WARNING: add it. Redeploy with --build, or in Dokploy tick Rebuild."
  else
    step_docker_config

    (
      # Explicit, NOT inherited, and the value is deliberate. The container
      # starts at -500 to keep tailscaled off the OOM killer's list, and
      # oom_score_adj is inherited by children, so leaving that alone would make
      # dockerd exactly as protected as the only route back into the box.
      # Interactive shells raise themselves to 0 (see .devaloy_env, written by
      # step_shell_env), so the ladder we want is: runaway build (0) dies first,
      # then dockerd, Paseo and T3 Code (-250), then tailscaled (-500). Raising
      # above an inherited value is unprivileged, so this needs no
      # CAP_SYS_RESOURCE.
      echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

      # Unbounded restart loop with a sleep. The sleep is what stops a crash-loop spinning hot on a daemon that cannot
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
step_browser_libs_check
step_runtime_flags
step_toolchain
step_t3code_upgrade
step_link_shims

# --- git: gh auth, identity, signing, clones ---
# gh auth runs after link-shims, which puts gh on root's PATH. The identity
# fallback asks gh, signing reads the identity's email, and the clones use the
# credential helper gh installed. Keep the four in this order.
step_gh_auth
step_git_identity
step_signing
step_clone_repos

# --- Paseo daemon (only when WITH_PASEO=true) ---
# A remote runtime: the Paseo phone, desktop, browser and CLI clients speak to a
# daemon, not a terminal, which Tailscale SSH alone cannot serve. Everything
# else about the box is unchanged.
#
# Read these choices before editing this block. They are deliberate, not drift:
#
#   * The KEY IS A RUNTIME VARIABLE, not a build arg. Paseo is a plain npm
#     package installed into the home volume by bootstrap-toolchain.sh, so there
#     is no image payload to gate and `docker compose up -d` is enough to flip
#     it.
#   * A MISSING BINARY IS A FAULT HERE, and warns. A missing paseo when the key
#     is on means the bootstrap failed, and the log should say so.
#   * IT BINDS THE TAILNET ADDRESS, not 0.0.0.0. Paseo's own default is
#     127.0.0.1, so this widens it exactly as far as the tailnet and no
#     further. Nothing lands on the docker bridge.
#   * IT IS CONFIGURED BY FILE, not by flags. Paseo has a config file that
#     every other `paseo` on the box reads too, so the settings live there. See
#     step_paseo_config in lib/steps/paseo.sh.
#
# Runs after link-shims on purpose: the daemon shells out to `claude` and
# `codex`, and `su -l -s /bin/sh` does NOT get the mise shims on PATH, only
# /usr/local/bin, which is exactly what link-shims mirrors them into. Start this
# any earlier and the agents the daemon launches fail to find their binary.
PASEO_PORT=6767

if [ "${WITH_PASEO:-false}" = "true" ]; then
  if as_dev "command -v paseo >/dev/null 2>&1"; then
    PASEO_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
    if [ -n "${PASEO_IP}" ]; then
      # Writes ~/.paseo/config.json and sets PASEO_START_ENV, which stays
      # empty unless that write failed.
      step_paseo_config

      (
        # Explicit, NOT inherited — see the identical note in the dockerd block.
        # The container starts at -500 to keep tailscaled off the OOM killer's
        # list, so an untouched daemon would be as protected as the only process
        # that keeps you connected. -250 sits above a runaway build and below
        # tailscaled.
        echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

        # A SECOND supervision layer, on purpose. `paseo daemon run` execs
        # Paseo's own supervisor, which restarts its worker on crash and holds a
        # PID lock under ~/.paseo. Nothing but this loop restarts the supervisor
        # itself, and it costs nothing while the inner layer is doing its job.
        # `run` is also what keeps the daemon's output in `docker compose logs`:
        # `paseo daemon start` detaches and writes to a file, and the container
        # log is the recovery surface when the tailnet is down.
        #
        # Paseo 0.10.3 removed `daemon start --foreground`, the command this
        # loop used before. It now exits at once with an error, so every pass
        # of the loop failed and the daemon never came up. `daemon run` takes
        # no listen or relay flags; overrides are environment variables.
        #
        # Sourcing the secrets file is load-bearing and not decoration. Agents
        # the daemon spawns inherit ITS environment, and as_dev runs
        # `su -l -s /bin/sh`, which reads neither .zshenv nor .bashrc — so
        # without this line CLAUDE_CODE_OAUTH_TOKEN never reaches a Claude Code
        # session started from the phone, and it falls back to a credentials
        # file a token-provisioned box does not have. Same trap step_gh_auth
        # exists to work around. It also carries PASEO_PASSWORD to the
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
        # PASEO_START_ENV is EMPTY on a healthy boot. The listen address, the
        # relay switch, the web UI and the hostnames all come from
        # ~/.paseo/config.json, so a `paseo daemon restart` you run over SSH
        # brings the daemon back exactly as this line starts it. The variable
        # only fills in when the config write in step_paseo_config failed.
        #
        # SHELL is exported because su exports whatever it was given with -s,
        # so as_dev hands the daemon SHELL=/bin/sh. Paseo opens a terminal from `env.SHELL || "/bin/sh"`
        # and never reads /etc/passwd, so without this line every pane from
        # cmd+t in the app lands in sh instead of the dev user's login shell.
        # There is no shell key in ~/.paseo/config.json, so this cannot move to
        # step_paseo_config. It is EXPORTED rather than written as a
        # command prefix because the `if` that follows is a compound command,
        # which takes no assignment prefix. The -s /bin/sh itself has to stay —
        # see as_dev.
        while true; do
          as_dev "export SHELL=/usr/bin/zsh; ${PASEO_START_ENV} \
            if [ -f '${SECRETS_SNIPPET}' ]; then . '${SECRETS_SNIPPET}'; fi; \
            paseo daemon run" || true
          log "WARNING: the Paseo daemon exited — restarting in 10s"
          sleep 10
        done
      ) &
      log "Paseo daemon on ${PASEO_IP}:${PASEO_PORT} — add it in the app under"
      log "Settings > Add host > Direct connection, with SSL off. The relay is"
      log "deliberately disabled, so the phone needs Tailscale connected."

      # In the BACKGROUND: it waits on the daemon the loop above just started.
      # See step_paseo_plugins for why it must not hold up the entrypoint.
      if [ -n "${PASEO_PLUGINS:-}" ]; then
        step_paseo_plugins &
      fi
    else
      # Same call as tailscale up's own failure path: a
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

# --- T3 Code server (only when WITH_T3CODE=true) ---
#
# The T3 Code desktop app on a laptop and the T3 Code phone app both speak to
# one server, `t3 serve`. It is a Paseo-shaped guest, and the block follows
# the Paseo block above:
#
#   * The KEY IS A RUNTIME VARIABLE. `t3` is an npm package in the home volume
#     (config/mise/optional/t3code.toml), so a missing binary with the key on
#     is a fault and warns.
#   * IT BINDS THE TAILNET ADDRESS. `--host <tailnet-ip>` keeps port 3773 off
#     the docker bridge. Both apps accept plain HTTP to a tailnet address, and
#     WireGuard already encrypts the traffic, so there is no Tailscale Serve
#     and no HTTPS.
#   * NO SETTINGS ARE WRITTEN. ~/.t3/userdata/settings.json belongs to the
#     apps. The two environment variables below are the whole configuration.
#
# Pairing is one-time links, not a password. `t3 serve` prints one with a QR
# code on every start, so the first device pairs from `docker compose logs`.
# `t3 pair` on the box finds the running server through
# ~/.t3/userdata/server-runtime.json and prints a fresh link with the same
# tailnet address, which is how the second device pairs without a restart.
# A link in the container log is a credential, but only to someone who can
# already `docker exec` in as root.
T3CODE_PORT=3773

if [ "${WITH_T3CODE:-false}" = "true" ]; then
  if as_dev "command -v t3 >/dev/null 2>&1"; then
    T3CODE_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
    if [ -n "${T3CODE_IP}" ]; then
      # Links ~/.t3/worktrees to ~/worktrees, the root Paseo uses too.
      step_t3code_config

      (
        # -250, the same slot as the Paseo daemon and for the same reason: above
        # a runaway build, below tailscaled. See the dockerd block.
        echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

        # The only supervisor. `t3 service install` needs systemd user units,
        # which this container does not run. A stale server-runtime.json after
        # a crash does not block the restart: only `t3 start` checks it, and
        # `t3 serve` does not.
        #
        # The secrets file is sourced for the reason spelt out at the Paseo
        # loop: agents inherit the server's environment, and as_dev reads no
        # shell rc file, so CLAUDE_CODE_OAUTH_TOKEN would not reach a Claude
        # Code thread started from the phone. The `if [ -f ]` guard is
        # load-bearing for the same dash reason. SHELL is exported for the same
        # reason as there too, so terminals open in zsh rather than sh.
        #
        # T3CODE_TELEMETRY_ENABLED=false keeps T3 Code's analytics off this box.
        # T3CODE_SERVER_BROWSER_SANDBOX=0 runs the server's headless Chrome
        # without its own sandbox, which needs user namespaces this container
        # does not give it. The container is the isolation layer. The browser
        # downloads on the first tab only, and a tab that cannot start fails
        # alone; the server keeps running.
        while true; do
          as_dev "export SHELL=/usr/bin/zsh; \
            export T3CODE_TELEMETRY_ENABLED=false T3CODE_SERVER_BROWSER_SANDBOX=0; \
            if [ -f '${SECRETS_SNIPPET}' ]; then . '${SECRETS_SNIPPET}'; fi; \
            t3 serve --host '${T3CODE_IP}' --port '${T3CODE_PORT}' --no-browser" || true
          log "WARNING: the T3 Code server exited — restarting in 10s"
          sleep 10
        done
      ) &
      log "T3 Code server on http://${T3CODE_IP}:${T3CODE_PORT} — pair the first device"
      log "with the link it prints below. For the next one, run on your laptop:"
      log "  ssh dev@${TS_HOSTNAME:-devaloy} t3 pair"
      log "Keep Tailscale connected on the phone."
    else
      # Same call as the Paseo block: a server on an address nothing can route
      # to fails at connect time rather than here, where the log can say why.
      log "WARNING: no tailnet IPv4 — not starting the T3 Code server."
      log "WARNING: fix the tailscale failure above, then restart the container."
    fi
  else
    log "WARNING: WITH_T3CODE is true but t3 is not installed. The toolchain"
    log "WARNING: bootstrap above did not finish — once you are in, re-run it"
    log "WARNING: with: devaloy-update"
  fi
fi

log "devaloy is up. Connect with: ssh dev@${TS_HOSTNAME:-devaloy}"
wait "${TAILSCALED_PID}"
