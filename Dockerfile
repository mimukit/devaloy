# syntax=docker/dockerfile:1.9
# BuildKit is required (Docker 23+ enables it by default). The `--mount=type=cache`
# and `COPY --chmod` directives below both need the 1.x frontend above.

# ---------------------------------------------------------------------------
# WHAT GOES WHERE
#
# The system install (apt repos, packages, the dev user, the CLI, build-flags)
# lives in lib/system/, and this file only calls it: one RUN per step, so each
# step keeps its own layer and cache. scripts/install-native.sh calls the same
# functions on a VM. A change to what a box carries goes in lib/system/ or
# config/apt/, never here, or the image and a native VM drift apart.
#
# What stays here is what only an image has: the fetch stage, the base image's
# ubuntu user, the entrypoint, the healthcheck.
#
# Every lib/system call comes in through a bind mount, not a COPY. The
# `COPY config` at the bottom of this file is last on purpose, and a COPY of
# lib/ high up would rebuild every layer below it on any edit. A bind mount
# makes a layer depend on the mounted files alone. The cost: an edit to a file
# in lib/system/ rebuilds the layers that mount it.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stage 1: network fetches that have nothing to do with the package list.
#
# These live in their own stage so that editing the apt package list, the one
# thing that actually churns, cannot invalidate them. SYS_ROOT points the
# steps at /out, and the final stage COPYs the result, so the final image
# needs no curl before its package layer.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS fetch

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates

# Tailscale's apt repo and the zsh-completions tarball. Both are in every box.
RUN --mount=type=bind,source=lib/system,target=/src/lib/system \
    SYS_ROOT=/out bash /src/lib/system/install.sh tailscale-repo zsh-completions

# Docker's apt repo, for the optional nested daemon (see WITH_DOCKER below).
#
# Note where this lands: /out-docker, NOT /out. /out is COPYed unconditionally
# into the final image, so putting the Docker repo there would add a keyring
# and a third-party repo to the *default* build, and make every `apt-get
# update` on a box that never asked for Docker reach download.docker.com. Its
# own directory means the WITH_DOCKER block can bind-mount it, and a default
# build carries no trace of it.
RUN --mount=type=bind,source=lib/system,target=/src/lib/system \
    SYS_ROOT=/out-docker bash /src/lib/system/install.sh docker-repo

# ---------------------------------------------------------------------------
# Stage 2: the image itself, ordered least-volatile first.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

# Keep apt's downloads in a BuildKit cache mount instead of deleting them. The
# package lists and .debs then survive across builds, so adding one package to
# the list re-downloads that package and nothing else: the difference between
# a ~90s apt layer and a ~5s one. Nothing is written into the image layer
# either way: both paths are mounts, not directories.
#
# ca-certificates comes along here rather than in the main package list because
# Tailscale's apt repo is HTTPS: without a trust store, the `apt-get update`
# in the package layer cannot even read the repo it installs tailscale from.
# This layer holds nothing volatile, so it stays cached indefinitely.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
        > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates

# ubuntu:24.04 ships a default "ubuntu" user/group at 1000:1000. Drop it so
# dev can claim that uid/gid predictably: the home volume's files belong to
# 1000. Image-only, because a VM keeps its cloud user as the console's way in.
# Done before apt so a package-list edit does not rebuild it.
RUN --mount=type=bind,source=lib/system,target=/src/lib/system \
    userdel -r ubuntu 2>/dev/null; groupdel ubuntu 2>/dev/null; \
    DEV_UID=1000 bash /src/lib/system/install.sh dev-user

# Tailscale's repo and zsh-completions, from the fetch stage.
COPY --from=fetch /out/ /

# The package list itself is config/apt/packages.txt, one package per line with
# a comment on each one that needs a reason.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=lib/system,target=/src/lib/system \
    --mount=type=bind,source=config/apt/packages.txt,target=/src/config/apt/packages.txt \
    REPO=/src bash /src/lib/system/install.sh base-packages

# ---------------------------------------------------------------------------
# OPTIONAL: nested Docker Engine and Compose (WITH_DOCKER). BEGIN
#
# Most projects you open on this box carry a docker-compose.yml and need it to
# start their development stack. This block puts a real Docker Engine in the
# image; entrypoint.sh starts the daemon inside the container, so the stacks run
# *here*, in devaloy's own filesystem and network namespace.
#
# THE HOST SOCKET IS NOT AN OPTION, and the reason is not squeamishness. A
# project compose file that says `./:/app` resolves that path on whichever
# machine owns the daemon: with the host socket that is the VPS, where
# /home/dev/proj does not exist, so every project breaks on its first bind
# mount. Published ports land on the VPS public interfaces rather than inside
# this container. And the socket is host root, on a box with passwordless sudo
# and AI agents, sharing a machine with live sites.
#
# The daemon needs the container's root to be root over its own namespaces. Two
# shapes give it that, and compose selects between them (see docker-compose.yml):
#
#   DEVALOY_PRIVILEGED=true       for a host you own alone. All host devices.
#   DEVALOY_RUNTIME=sysbox-runc   for a shared host. No privilege at all.
#
# OFF BY DEFAULT: it is an opt-in capability, not part of devaloy's baseline.
# It is a BUILD arg, so `docker compose up -d` alone will not pick up a change
# to it. You need `--build`.
#
# Placed here, above the COPY lines below, so editing entrypoint.sh or config/
# never rebuilds this package install.
# ---------------------------------------------------------------------------
ARG WITH_DOCKER=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=lib/system,target=/src/lib/system \
    --mount=type=bind,from=fetch,source=/out-docker,target=/tmp/docker-apt \
    if [ "${WITH_DOCKER}" = "true" ]; then cp -a /tmp/docker-apt/. /; fi \
    && bash /src/lib/system/install.sh docker-engine
# --- OPTIONAL: nested Docker Engine and Compose. END ---

# ---------------------------------------------------------------------------
# OPTIONAL: headless browser capture (WITH_BROWSER). BEGIN
#
# The system half of `playwright-cli`. The list is config/apt/browser.txt.
# One block of its own, not folded into the package layer, so flipping
# WITH_BROWSER does not invalidate that layer. The browser itself is NOT here:
# Playwright's Chromium is a per-release download into ~/.cache/ms-playwright,
# the home volume, so bootstrap-toolchain.sh installs it next to the npm
# package that drives it.
#
# No assertion at the end, unlike the Docker block: there is no binary in the
# image to `ldd`. The first launch on the box is the check, and entrypoint.sh
# warns when this block is missing from an image that the key says should
# carry it.
#
# OFF BY DEFAULT, like WITH_DOCKER. Measured on arm64 it takes the image from
# 660 MB to 1.09 GB; ffmpeg's dependency tree is most of that. It is a BUILD
# arg, so you need `--build`. The same key is also read at runtime, by the
# bootstrap and the entrypoint; see compose.
# ---------------------------------------------------------------------------
ARG WITH_BROWSER=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=lib/system,target=/src/lib/system \
    --mount=type=bind,source=config/apt/browser.txt,target=/src/config/apt/browser.txt \
    REPO=/src bash /src/lib/system/install.sh browser-packages
# --- OPTIONAL: headless browser capture. END ---

# No sshd, no authorized_keys, no host keys: Tailscale SSH is the only way in,
# and it authenticates from tailnet identity plus the tailnet policy file.
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# The CLI: devaloy, bootstrap-toolchain.sh and link-shims in /usr/local/bin,
# lib/ in /usr/local/lib/devaloy, and the five old verb names as symlinks.
# The same copy routine `devaloy update` runs on a native VM.
RUN --mount=type=bind,source=devaloy,target=/src/devaloy \
    --mount=type=bind,source=bootstrap-toolchain.sh,target=/src/bootstrap-toolchain.sh \
    --mount=type=bind,source=link-shims,target=/src/link-shims \
    --mount=type=bind,source=lib,target=/src/lib \
    REPO=/src bash /src/lib/system/install.sh cli

# The build flags, recorded for `devaloy doctor`. See sys_build_flags in
# lib/system/steps.sh for why doctor needs them. RUNTIME=container tells the
# CLI and the boot steps which kind of box this is; the native installer
# writes RUNTIME=native.
RUN --mount=type=bind,source=lib/system,target=/src/lib/system \
    RUNTIME=container bash /src/lib/system/install.sh build-flags

# Claude Code and Codex are not installed here. mise's registry covers both and
# fetches the same upstream artifacts their own installers do, so they live in
# bootstrap-toolchain.sh with the rest of the toolchain: one package manager,
# and an upgrade that persists in the home volume instead of dying on the next
# rebuild.

# Managed dotfiles. entrypoint.sh copies zsh, Claude Code and Codex into
# /home/dev on every boot; see the "config sync" section of the README for what
# that overwrites and what it leaves alone. config/nvim is the exception:
# bootstrap-toolchain.sh seeds it ONCE, so your editor config on the box is
# yours to edit. devaloy-nvim-sync re-copies it on demand. Last, because it is
# what changes most often and nothing below it needs rebuilding.
COPY config /opt/devaloy/config

# No VOLUME instruction: compose declares the named volumes, and Docker seeds an
# empty named volume from the image either way. Declaring it here would only
# force an anonymous volume on a plain `docker run`.

# The Docker health state, for `docker ps`, `docker inspect` and dashboards such
# as Beszel. Without it Docker reports health as "none".
#
# `devaloy health` answers one question: can you get into the box? Tailscale's
# backend is Running, and where the entrypoint starts dockerd, `docker info`
# answers. It uses nothing from mise, so a slow or failed toolchain bootstrap on
# a cold volume never makes the box unhealthy; `devaloy doctor` reports that.
#
# The start period covers `tailscale up` (90 s timeout) and the dockerd socket
# wait (30 s). The start interval probes every 5 s inside it, so the state turns
# healthy seconds after the tailnet is up; it needs Docker Engine 25 or later on
# the host. Three misses 30 s apart make a fault last about 90 s before the
# state changes, so one dockerd restart (a 10 s sleep) never flips it.
#
# UNHEALTHY RESTARTS NOTHING. `restart: unless-stopped` acts when the container
# exits, never on health, and that is the point: a restart kills every agent
# session on the box. Keep it that way. Do not deploy this under Swarm, and do
# not run an autoheal container that watches every container on the host; both
# restart an unhealthy container.
HEALTHCHECK --interval=30s --timeout=10s --start-period=3m --start-interval=5s --retries=3 \
    CMD ["/usr/local/bin/devaloy", "health"]

ENTRYPOINT ["/entrypoint.sh"]
