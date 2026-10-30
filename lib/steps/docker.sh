#!/usr/bin/env bash
# devaloy boot steps: the nested Docker daemon's config.
#
# Sourced by entrypoint.sh after common.sh, never executed. The daemon start,
# its restart loop and the socket wait stay in entrypoint.sh, which calls this
# step only when WITH_DOCKER=true and dockerd is in the image.

# The shipped daemon config. This needs its own copy line: the config sync in
# step_seed_config targets /home/dev, and dockerd reads /etc/docker. JSON takes
# no comments, so what it carries and why is in config/docker/README.md — the
# short version is that it pins the nested bridge into 10.x, away from the
# 172.16/12 space the outer host allocates from.
step_docker_config() {
  mkdir -p /etc/docker
  if [ -f "${CONFIG_SRC}/docker/daemon.json" ]; then
    cp "${CONFIG_SRC}/docker/daemon.json" /etc/docker/daemon.json
  else
    log "WARNING: ${CONFIG_SRC}/docker/daemon.json is missing — starting dockerd"
    log "WARNING: on its defaults. Expect a 172.17.0.0/16 bridge, which can"
    if on_native; then
      log "WARNING: collide with this VM's own network."
    else
      log "WARNING: collide with this container's own network."
    fi
  fi
}
