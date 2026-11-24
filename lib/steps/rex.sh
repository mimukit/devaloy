#!/usr/bin/env bash
# devaloy boot steps: dev's Rex server (WITH_REX=true).
#
# Sourced by entrypoint.sh and native-boot.sh after common.sh, never executed.
# The rex package itself comes from the system layer (sys_rex_package in
# lib/system/steps.sh): the image installs it at build time, the native
# installer at install time.
#
# Rex is a terminal-session server. A client on a laptop reaches it over
# Tailscale SSH and attaches to the sessions it keeps, so the server opens no
# port and binds no tailnet address. It runs as dev, so its terminals are dev's
# shells.
#
# Two ways to keep it running, picked by whether systemd runs this box:
#
#   container   `rex server start` as dev. It detaches, and it is idempotent:
#               a server that already runs is left alone.
#   native VM   the package's own user units: rex.socket in dev's systemd user
#               manager, which starts the server on the first connection, plus
#               lingering, which keeps that manager up with no one logged in.
#               This is what `rex server install` sets up, done as root.
#
# A client that finds no server starts one itself, so this step is about a
# server that is already there, with its sessions, when you connect.

step_rex_server() {
  if [ "${WITH_REX:-false}" != "true" ]; then
    # A container restart already ends the old server.
    if on_native && {
      systemctl --user -M "${DEV_USER}@" is-enabled --quiet rex.socket 2>/dev/null ||
      systemctl --user -M "${DEV_USER}@" is-active --quiet rex.socket rex.service 2>/dev/null
    }; then
      if systemctl --user -M "${DEV_USER}@" disable --now --quiet rex.socket &&
         systemctl --user -M "${DEV_USER}@" stop rex.service; then
        log "Rex: stopped the server and disabled socket activation"
      else
        log "WARNING: could not stop the Rex server or disable rex.socket."
      fi
    fi
    return 0
  fi

  if [ ! -x /usr/bin/rex ]; then
    log "WARNING: WITH_REX is true but rex is not installed."
    if on_native; then
      log "WARNING: re-run the native installer with WITH_REX=true."
    else
      log "WARNING: WITH_REX is a BUILD argument too. Rebuild with"
      log "WARNING: 'docker compose up -d --build'."
    fi
    return 0
  fi

  if on_native; then
    # enable-linger starts dev's user manager in the background. Starting its
    # unit as well waits for it, so the systemctl --user call below has a
    # manager to talk to.
    if loginctl enable-linger "${DEV_USER}" &&
       systemctl start "user@$(id -u "${DEV_USER}").service" &&
       systemctl --user -M "${DEV_USER}@" enable --now --quiet rex.socket; then
      log "Rex: dev's server starts on the first connection (rex.socket)"
    else
      log "WARNING: could not enable rex.socket for dev. A client still starts"
      log "WARNING: a server when it connects. See 'systemctl --user -M ${DEV_USER}@ status rex.socket'."
    fi
  else
    # -250, the same slot as the Paseo and T3 Code servers: above a runaway
    # build, below tailscaled. The detached server keeps the value.
    #
    # SHELL is exported because `su -l -s /bin/sh` sets it to /bin/sh, and the
    # server would then open its terminals in sh rather than zsh.
    if ( echo -250 > /proc/self/oom_score_adj 2>/dev/null || true
         as_dev "export SHELL=/usr/bin/zsh; /usr/bin/rex server start" >/dev/null ); then
      log "Rex: dev's server is running"
    else
      log "WARNING: could not start dev's Rex server. A client still starts one"
      log "WARNING: when it connects. Run 'rex server start' as dev to see why."
    fi
  fi
  log "Rex: connect from your laptop over Tailscale SSH to dev@${TS_HOSTNAME:-devaloy}"
}
