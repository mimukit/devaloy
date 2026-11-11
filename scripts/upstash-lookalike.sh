#!/usr/bin/env bash
# A local look-alike of an Upstash Box, for testing the Upstash runtime on a
# devaloy box with a Docker daemon.
#
#   scripts/upstash-lookalike.sh start          create (or start) the container
#   scripts/upstash-lookalike.sh sync           copy the working tree in again
#   scripts/upstash-lookalike.sh shell [CMD]    a shell, or CMD, as boxuser
#   scripts/upstash-lookalike.sh root [CMD]     the same, as root
#   scripts/upstash-lookalike.sh stop           remove the container and volume
#
# What it copies from a real box (plan 0016, the Tests row): Debian 12, a
# `boxuser` with uid and gid 1002 and passwordless sudo, curl, git and sudo,
# a /workspace volume with /workspace/home in it, the Upstash links from
# /home/boxuser (.claude, .codex, .cursor and .local/share) into it, PID 1
# `tail -f /dev/null` under an init, the three UPSTASH_BOX_* variables, and
# Node at /usr/local/bin/node (the real box has Node 25; node:22-bookworm is
# close enough for the SDK step's preflight). No extra capabilities and no
# /dev/net/tun, as on the real box. What it cannot copy: the architecture
# (this box is x86_64, an Upstash Box is aarch64), the preview proxy, and the
# runner in /opt/runner.
#
# The repo goes in as a git repo at /srv/devaloy with one commit on `main`
# that holds the working tree as it is now, uncommitted changes and untracked
# files included, so the installer runs what is on disk here and not what is
# on GitHub. Point the installer at it with DEVALOY_SRC=/srv/devaloy.
set -euo pipefail

NAME=devaloy-upstash-lookalike
VOLUME="${NAME}-workspace"
IMAGE=node:22-bookworm
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exists() { docker container inspect "${NAME}" >/dev/null 2>&1; }

# The working tree as one commit. A clone of the repo gives the history; the
# files are then replaced with what the work tree holds, less what git
# ignores, and committed in the temp clone only. Nothing in REPO changes.
sync_repo() {
  local tmp
  tmp="$(mktemp -d)"
  git clone --quiet --no-local "${REPO}" "${tmp}/devaloy"
  git -C "${tmp}/devaloy" checkout --quiet -B main
  find "${tmp}/devaloy" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  # A file deleted in the work tree is still in the index; it is left out.
  (cd "${REPO}" && git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ -e "${f}" ] && printf '%s\0' "${f}"; done |
    tar --null -cf - -T -) | tar -xf - -C "${tmp}/devaloy"
  git -C "${tmp}/devaloy" add -A
  git -C "${tmp}/devaloy" -c user.name=lookalike -c user.email=lookalike@localhost \
    commit --quiet --allow-empty -m "lookalike snapshot of the working tree"
  docker exec "${NAME}" rm -rf /srv/devaloy
  docker exec "${NAME}" mkdir -p /srv
  docker cp --quiet "${tmp}/devaloy" "${NAME}:/srv/devaloy"
  docker exec "${NAME}" chown -R 1002:1002 /srv/devaloy
  docker exec "${NAME}" git config --system --add safe.directory /srv/devaloy
  rm -rf "${tmp}"
  echo "lookalike: /srv/devaloy holds the working tree at $(git -C "${REPO}" rev-parse --short HEAD) plus local changes"
}

start() {
  if exists; then
    docker start "${NAME}" >/dev/null
    echo "lookalike: ${NAME} started"
    return 0
  fi
  docker volume create "${VOLUME}" >/dev/null
  docker run -d --name "${NAME}" --hostname "${NAME}" --init \
    -v "${VOLUME}:/workspace" \
    -e UPSTASH_BOX_ID=lookalike-0 \
    -e UPSTASH_BOX_NAME=lookalike \
    -e UPSTASH_BOX_RUNTIME=node \
    -e NPM_CONFIG_CACHE=/tmp/.npm-cache \
    "${IMAGE}" tail -f /dev/null >/dev/null
  docker exec "${NAME}" bash -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -q update >/dev/null
    apt-get -q install -y --no-install-recommends sudo curl git ca-certificates >/dev/null
    groupadd -g 1002 boxuser
    useradd -m -u 1002 -g 1002 -s /bin/bash boxuser
    echo "boxuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/boxuser
    chmod 440 /etc/sudoers.d/boxuser
    # A real box has /workspace as root:root 0711, and the box user owns
    # only /workspace/home. Keep that, so the installer meets the same wall.
    chown 0:0 /workspace
    chmod 711 /workspace
    # The links Upstash keeps in the old home.
    for d in /workspace/home /workspace/home/.local /home/boxuser/.local; do
      install -d -o 1002 -g 1002 "${d}"
    done
    for d in .claude .codex .cursor .local/share; do
      install -d -o 1002 -g 1002 "/workspace/home/${d}"
      ln -sfn "/workspace/home/${d}" "/home/boxuser/${d}"
      chown -h 1002:1002 "/home/boxuser/${d}"
    done'
  echo "lookalike: ${NAME} created (volume ${VOLUME})"
  sync_repo
}

run_in() { # run_in USER [CMD...]
  local user="$1" flags=(-i)
  shift
  [ -t 0 ] && [ -t 1 ] && flags=(-it)
  exists || { echo "lookalike: not running; run start first." >&2; exit 1; }
  if [ $# -eq 0 ]; then
    exec docker exec "${flags[@]}" -u "${user}" -w /workspace "${NAME}" bash -l
  fi
  exec docker exec "${flags[@]}" -u "${user}" -w /workspace "${NAME}" bash -lc "$*"
}

stop() {
  if exists; then
    docker rm -f "${NAME}" >/dev/null
    echo "lookalike: ${NAME} removed"
  fi
  if docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
    docker volume rm "${VOLUME}" >/dev/null
    echo "lookalike: volume ${VOLUME} removed"
  fi
}

case "${1:-}" in
  start) start ;;
  sync) exists || { echo "lookalike: not running; run start first." >&2; exit 1; }; sync_repo ;;
  shell) shift; run_in boxuser "$@" ;;
  root) shift; run_in root "$@" ;;
  stop) stop ;;
  *)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
