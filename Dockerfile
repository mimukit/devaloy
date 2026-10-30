# syntax=docker/dockerfile:1.9
# BuildKit is required (Docker 23+ enables it by default). The `--mount=type=cache`
# and `COPY --chmod` directives below both need the 1.x frontend above.

# ---------------------------------------------------------------------------
# Stage 1: network fetches that have nothing to do with the package list.
#
# These live in their own stage so that editing the apt package list — the one
# thing in this file that actually churns — cannot invalidate them. The stage
# only ever re-runs when a pinned version or URL on one of these lines changes.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS fetch

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates

# zsh-completions has no package in noble — only autosuggestions and
# syntax-highlighting do — so it comes from a pinned release tarball. Baked in
# here rather than cloned at first boot, which is the same bargain the other
# two get. It is a directory of completion functions, not something to source:
# zshrc puts src/ on fpath ahead of compinit.
ARG ZSH_COMPLETIONS_VERSION=0.36.0
RUN mkdir -p /out/usr/share/zsh-completions \
    && curl -fsSL "https://github.com/zsh-users/zsh-completions/archive/refs/tags/${ZSH_COMPLETIONS_VERSION}.tar.gz" \
    | tar -xz -C /out/usr/share/zsh-completions --strip-components=1

# tailscaled lives *inside* the final image on purpose. Tailscale SSH terminates
# the connection in whichever container runs tailscaled and spawns the shell
# there — so a sidecar sharing only the network namespace would drop you into
# the sidecar's filesystem, not this one. See tailscale/tailscale#5215.
RUN mkdir -p /out/usr/share/keyrings /out/etc/apt/sources.list.d \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        -o /out/usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        -o /out/etc/apt/sources.list.d/tailscale.list

# Docker's apt repo, for the optional nested daemon (see WITH_DOCKER below).
#
# Note where this lands: /out/docker, NOT the /out/usr/share/keyrings and
# /out/etc/apt/sources.list.d directories above. Those two are COPYed
# unconditionally into the final image, so putting the Docker repo there would
# add a keyring and a third-party repo to the *default* build — and make every
# `apt-get update` on a box that never asked for Docker reach
# download.docker.com. Keeping it in its own directory means the WITH_DOCKER
# block below can bind-mount it, and a default build carries no trace of it.
#
# The architecture comes from dpkg rather than being hardcoded. Both stages are
# the same platform, so this resolves correctly on an ARM VPS.
RUN mkdir -p /out/docker \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /out/docker/docker.asc \
    && chmod a+r /out/docker/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /out/docker/docker.list

# ---------------------------------------------------------------------------
# Stage 2: the image itself, ordered least-volatile first.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

# Keep apt's downloads in a BuildKit cache mount instead of deleting them. The
# package lists and .debs then survive across builds, so adding one package to
# the list below re-downloads that package and nothing else — the difference
# between a ~90s apt layer and a ~5s one. Nothing is written into the image
# layer either way: both paths are mounts, not directories.
#
# ca-certificates comes along here rather than in the main package list because
# Tailscale's apt repo is HTTPS: without a trust store, the `apt-get update`
# below cannot even read the repo it is about to install tailscale from. This
# layer holds nothing volatile, so it stays cached indefinitely.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
        > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates

# ubuntu:24.04 ships a default "ubuntu" user/group at 1000:1000 — drop it so
# our dev user can claim that uid/gid predictably.
# The login shell is read from /etc/passwd, which lives in this image rather
# than the home volume — so zsh is the shell Tailscale SSH spawns from the
# first boot onward, with no chsh needed on the box. Done before apt so a
# package-list edit doesn't rebuild it; /etc/passwd holds a path string, and
# does not care that zsh isn't installed yet (hence useradd's warning).
# /etc/sudoers.d normally arrives with the sudo package, which is also not
# installed yet — so create it here. dpkg leaves an existing directory and the
# drop-in inside it alone when sudo lands below.
RUN userdel -r ubuntu 2>/dev/null; groupdel ubuntu 2>/dev/null; \
    groupadd --gid 1000 dev \
    && useradd --uid 1000 --gid dev --create-home --shell /usr/bin/zsh dev \
    && mkdir -p /etc/sudoers.d \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev

# Tailscale's apt repo, in place before the single apt pass below so tailscale
# installs alongside everything else rather than paying for a second
# update/install round trip.
COPY --from=fetch /out/usr/share/keyrings/ /usr/share/keyrings/
COPY --from=fetch /out/etc/apt/sources.list.d/ /etc/apt/sources.list.d/

# The package list itself is config/apt/packages.txt, one package per line with
# a comment on each one that needs a reason. It lives there rather than inline
# because the native installer reads the same file, and two copies of a list
# drift. It comes in through a bind mount, not a COPY: the `COPY config` at the
# bottom of this file is last on purpose, and a COPY here would rebuild every
# layer below on any config edit. The bind mount makes this layer depend on
# this one file alone, so an edit to browser.txt does not rebuild it.
#
# The sed strips comments and blank lines, because apt-get takes neither. The
# list goes through a variable rather than a pipe into xargs, and the variable
# is checked: /bin/sh has no pipefail, so a missing file piped into xargs would
# run `apt-get install` with no packages, succeed, and ship an image with no
# git, no zsh and no tailscale.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=config/apt/packages.txt,target=/tmp/apt/packages.txt \
    pkgs="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /tmp/apt/packages.txt)" \
    && [ -n "${pkgs}" ] \
    && apt-get update \
    # Unquoted on purpose: one word per package.
    && apt-get install -y --no-install-recommends ${pkgs} \
    # Ubuntu ships bat as `batcat` to avoid a name clash with bacula-console.
    # Link it in /usr/bin, not /usr/local/bin — link-shims owns the latter and
    # will overwrite a symlink it finds there.
    # Ubuntu ships fd as `fdfind` for the same reason (clash with fdclone).
    # LazyVim looks for `fd` first and falls back to `fdfind`, but plenty of
    # plugins only know the short name.
    && ln -s /usr/bin/batcat /usr/bin/bat \
    && ln -s /usr/bin/fdfind /usr/bin/fd

COPY --from=fetch /out/usr/share/zsh-completions/ /usr/share/zsh-completions/

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
    --mount=type=bind,from=fetch,source=/out/docker,target=/tmp/docker-apt \
    if [ "${WITH_DOCKER}" = "true" ]; then \
        cp /tmp/docker-apt/docker.asc /usr/share/keyrings/docker.asc \
        && cp /tmp/docker-apt/docker.list /etc/apt/sources.list.d/docker.list \
        # The repo stays in the image rather than being removed afterwards, so
        # `apt-get upgrade` on the box moves Docker the way it moves tailscale.
        && apt-get update && apt-get install -y --no-install-recommends \
            # docker-ce is the daemon, docker-ce-cli the client, containerd.io
            # the runtime underneath both. The two plugins are separate packages
            # and neither is pulled in by the others: without docker-compose-
            # plugin there is no `docker compose` at all, which is the entire
            # point of this block.
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin \
        # The `docker` group does not exist until docker-ce lands, so this
        # cannot move up to the useradd line near the top of this stage. Without
        # it every docker call on the box needs sudo.
        && usermod -aG docker dev \
        # Assert what the entrypoint will reach for, so a broken install fails
        # the build rather than the first boot. All three run without a daemon, so they are safe in a
        # build: the first is the binary entrypoint.sh supervises, and the other
        # two are the plugins apt would happily leave out.
        && [ -x /usr/bin/dockerd ] \
        && docker compose version \
        && docker buildx version; \
    fi
# --- OPTIONAL: nested Docker Engine and Compose. END ---

# ---------------------------------------------------------------------------
# OPTIONAL: headless browser capture (WITH_BROWSER). BEGIN
#
# The system half of `playwright-cli`: the shared libraries a headless Chromium
# needs to start on a minimal noble base, plus ffmpeg. The browser itself is NOT
# here. Playwright's Chromium is a per-release download that lands in
# ~/.cache/ms-playwright, which is the home volume, so bootstrap-toolchain.sh
# installs it next to the npm package that drives it. That is the same split
# WITH_DOCKER makes between the engine (image) and its data (volume): the part
# apt owns lives in the image, the part that moves with a `devaloy-update` lives
# where an update can reach it.
#
# One contiguous block, deliberately not folded into the apt list above, for two
# reasons: removing it later is deleting one unit, and flipping WITH_BROWSER
# does not invalidate the main apt layer. The cost is one extra apt-get update
# round trip, which is cheap behind the cache mounts it shares with every other
# apt call here.
#
# The library set is what `playwright install-deps chromium` resolves on noble,
# listed by hand so a build never runs an installer script as root. ffmpeg is
# here for GIF conversion: Playwright ships its own ffmpeg build for video
# recording, but that build only records, and a webm from `video-stop` needs
# a real ffmpeg to become a GIF.
#
# No assertion at the end, unlike the Docker block, and that is not
# an oversight: there is no binary in the image to `ldd`. The first launch on
# the box is the check, and entrypoint.sh warns when this block is missing from
# an image that the key says should carry it.
#
# OFF BY DEFAULT, like WITH_DOCKER: an opt-in capability, not
# part of devaloy's baseline. Measured on arm64 it takes the image from 660 MB
# to 1.09 GB; ffmpeg's dependency tree is most of that. It is a BUILD arg, so
# `docker compose up -d` alone will not pick up a change to it. You need
# `--build`. The same key is also read at runtime, by the bootstrap and the
# entrypoint — see compose.
#
# The list is config/apt/browser.txt, read the same way as packages.txt above
# and for the same reason: the native installer reads that file too.
# ---------------------------------------------------------------------------
ARG WITH_BROWSER=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=config/apt/browser.txt,target=/tmp/apt/browser.txt \
    if [ "${WITH_BROWSER}" = "true" ]; then \
        pkgs="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /tmp/apt/browser.txt)" \
        && [ -n "${pkgs}" ] \
        && apt-get update \
        && apt-get install -y --no-install-recommends ${pkgs}; \
    fi
# --- OPTIONAL: headless browser capture. END ---

# No sshd, no authorized_keys, no host keys: Tailscale SSH is the only way in,
# and it authenticates from tailnet identity plus the tailnet policy file.
COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 bootstrap-toolchain.sh devaloy link-shims /usr/local/bin/

# The devaloy modules. A fixed list, and `devaloy` refuses to start when one is
# missing — see the loader comment there for why a glob would be worse.
COPY lib /usr/local/lib/devaloy

# The five old command names. Symlinks rather than wrapper scripts: `devaloy`
# reads its own basename and infers the verb, so there is nothing to keep in
# sync. `ls -l /usr/local/bin` then shows a reader exactly what the old names
# became.
RUN set -eux; \
    for name in devaloy-update devaloy-disk devaloy-ram devaloy-prune devaloy-nvim-sync; do \
        ln -sfn /usr/local/bin/devaloy "/usr/local/bin/${name}"; \
    done

# The build flags, recorded for `devaloy doctor`.
#
# THIS IS WHY DOCTOR CAN HAVE AN EXIT CODE. "Docker is not reachable" is the
# same observation whether the box was never built with it or the daemon died,
# and those need opposite answers: the first is a correct minimal box, the
# second is a fault worth failing a script on. The probe alone cannot tell them
# apart, so the build writes down what was asked for.
#
# WITH_PASEO and WITH_T3CODE are deliberately absent. They are runtime variables
# that `docker compose up -d` can flip without a rebuild, so a value baked in
# here would go stale; entrypoint.sh records them in /opt/devaloy/runtime-flags
# on every boot, and doctor reads them there and from whether the daemon or the
# server is running.
#
# RUNTIME=container tells the CLI and the boot steps which kind of box this is.
# The native installer writes the same file with RUNTIME=native, and the
# difference decides what `devaloy doctor` and `devaloy health` check (processes
# the entrypoint supervises, or systemd units) and which recovery command a
# failed step prints. An image built before this key reads as container.
RUN mkdir -p /opt/devaloy \
    && printf 'WITH_DOCKER=%s\nWITH_BROWSER=%s\nRUNTIME=container\n' \
        "${WITH_DOCKER}" "${WITH_BROWSER}" \
        > /opt/devaloy/build-flags

# Claude Code and Codex are not installed here. mise's registry covers both and
# fetches the same upstream artifacts their own installers do, so they live in
# bootstrap-toolchain.sh with the rest of the toolchain — one package manager,
# and an upgrade that persists in the home volume instead of dying on the next
# rebuild.

# Managed dotfiles. entrypoint.sh copies zsh, Claude Code and Codex into
# /home/dev on every boot — see the "config sync" section of the README for what
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
