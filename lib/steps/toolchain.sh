#!/usr/bin/env bash
# devaloy boot steps: the runtime flags, the mise toolchain and the shim mirror.
#
# Sourced by entrypoint.sh after common.sh, never executed.

# WITH_BROWSER is the one key the toolchain reads that is ALSO a build argument.
# The bootstrap installs the CLI and the browser into the home volume on this
# key alone, but Chromium cannot start without the libraries the Dockerfile
# block puts in the image — so a box that set the key without --build gets a
# working `playwright-cli` and a browser that dies on a missing .so. Same trap
# as WITH_DOCKER, and warned about the same way. libnss3 is the probe because it
# is the first library Chromium loads and it is in no other block of the image.
#
# On a native VM the list is config/apt/browser.txt, and the installer is what
# puts it on the box, so the fix is a re-run of the installer with the key set,
# not a rebuild that does not exist there.
step_browser_libs_check() {
  if [ "${WITH_BROWSER:-false}" = "true" ] && ! dpkg -s libnss3 >/dev/null 2>&1; then
    if on_native; then
      log "WARNING: WITH_BROWSER=true but the Chromium libraries are not installed."
      log "WARNING: re-run the native installer with WITH_BROWSER=true to add the"
      log "WARNING: packages in ${CONFIG_SRC}/apt/browser.txt."
    else
      log "WARNING: WITH_BROWSER=true but the Chromium libraries are not in this image."
      log "WARNING: WITH_BROWSER is also a BUILD argument — 'docker compose up -d' cannot"
      log "WARNING: add them. Redeploy with --build, or in Dokploy tick Rebuild."
    fi
  fi
}

# The runtime keys, recorded for every process that is not a child of this
# script. The keys live in PID 1's environment, and no shell on the box inherits
# it, so `devaloy update` used to run the bootstrap with both keys unset. The
# bootstrap read that as "off" and deleted the Paseo and browser fragments.
# Sits beside build-flags and is rewritten on every boot, so a key flipped by
# `docker compose up -d` is never stale. The home volume would be the wrong
# place: a file there outlives the container that wrote it.
#
# A native VM has the same gap for a different reason: the keys live in
# /etc/devaloy/env, which only root can read, and devaloy-boot.service runs
# this step on every boot so a dev shell sees them here instead.
#
# WITH_DOCKER is here too, although it is also a build arg. The build arg puts
# dockerd in the image; this key is what the dockerd block in entrypoint.sh
# reads to start it. `devaloy health` needs the second answer, and the Docker
# healthcheck gets it from the container environment while an SSH shell does
# not. Recording it here makes a manual `devaloy health` judge the same box the
# healthcheck does.
#
# Built as a staging copy and swapped in by commit_staged (common.sh), so a
# boot with the same keys leaves the file and its mtime alone.
step_runtime_flags() {
  printf 'WITH_PASEO=%s\nWITH_BROWSER=%s\nWITH_T3CODE=%s\nWITH_DOCKER=%s\n' \
    "${WITH_PASEO:-false}" "${WITH_BROWSER:-false}" "${WITH_T3CODE:-false}" \
    "${WITH_DOCKER:-false}" \
    > "/opt/devaloy/runtime-flags${STAGED}"
  chmod 644 "/opt/devaloy/runtime-flags${STAGED}"
  commit_staged "/opt/devaloy/runtime-flags${STAGED}" /opt/devaloy/runtime-flags
}

# --- mise bootstrap + pinned toolchain (runs as dev) ---
# The skip-if-already-installed decision lives in bootstrap-toolchain.sh, not
# here: it hashes the toolset that config/mise/config.toml declares (plus the
# optional fragments the keys turn on) and compares that against the marker in
# the home volume. Keeping the check next to the config it hashes is what stops
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
# bootstrap died at `mise use` and never wrote its marker. `node` is a
# registry entry, which is why it is safe. Paseo now tracks latest
# with no variable at all — see the comment in bootstrap-toolchain.sh.
#
# Sets TOOLCHAIN_OK to 1 or 0. The container ignores it; the native boot
# script (native-boot.sh) fails its unit on 0, because the native installer
# promises to exit 0 only once the toolchain is ready.
step_toolchain() {
  log "Checking the mise toolchain"
  # shellcheck disable=SC2034  # read by native-boot.sh, not by this file.
  TOOLCHAIN_OK=0
  if as_dev "MISE_NODE_VERSION='${MISE_NODE_VERSION:-}' \
      WITH_PASEO='${WITH_PASEO:-false}' \
      WITH_BROWSER='${WITH_BROWSER:-false}' \
      WITH_T3CODE='${WITH_T3CODE:-false}' \
      /usr/local/bin/bootstrap-toolchain.sh"; then
    # shellcheck disable=SC2034  # as above.
    TOOLCHAIN_OK=1
    log "Toolchain ready"
  else
    log "WARNING: toolchain bootstrap failed — the box is still reachable."
    log "WARNING: once you are in, re-run it with: devaloy-update"
  fi
}

# --- T3 Code upgrades on every boot ---
# The one exception to the install-only boot path above. The T3 Code apps
# update themselves from the stores and refuse a server on another protocol
# version, so a box that keeps its t3 until someone runs `devaloy update` goes
# dark on the phone a few days after each release. The server starts fresh at
# boot anyway, after this step, so there is no live session to swap it under.
#
# npm:t3 only. Every other tool keeps the install-only rule, and `devaloy
# update` stays the way to move them. Non-fatal: an offline boot keeps the
# version already on the volume.
step_t3code_upgrade() {
  if [ "${WITH_T3CODE:-false}" = "true" ]; then
    if as_dev "MISE_MINIMUM_RELEASE_AGE=0s '${DEV_HOME}/.local/bin/mise' upgrade npm:t3"; then
      log "T3 Code: $(as_dev "'${DEV_HOME}/.local/share/mise/shims/t3' --version" 2>/dev/null || echo 't3') is current"
    else
      log "WARNING: could not upgrade t3, so the server starts on the version it has."
    fi
  fi
}

# Make the toolchain resolvable from sessions that never source .bashrc.
step_link_shims() {
  DEV_HOME="${DEV_HOME}" /usr/local/bin/link-shims || \
    log "WARNING: link-shims failed — non-interactive commands may not find the toolchain."
}
