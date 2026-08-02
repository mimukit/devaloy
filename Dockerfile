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

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        git \
        tmux \
        build-essential \
        curl \
        ca-certificates \
        vim \
        htop \
        btop \
        bat \
        jq \
        zsh \
        # Sourced from /usr/share by config/zsh/zshrc. Distro packages rather
        # than a plugin manager: the point is that a cold boot clones nothing.
        zsh-autosuggestions \
        zsh-syntax-highlighting \
        python3 \
        python3-pip \
        python3-venv \
        python-is-python3 \
        iproute2 \
        iptables \
        openssh-client \
        # Codex's Linux sandbox. It looks for `bwrap` on PATH and warns on every
        # start when it can't find one, falling back to the copy bundled in its
        # binary. The distro package is what upstream asks for.
        bubblewrap \
        tailscale \
    # Ubuntu ships bat as `batcat` to avoid a name clash with bacula-console.
    # Link it in /usr/bin, not /usr/local/bin — link-shims owns the latter and
    # will overwrite a symlink it finds there.
    && ln -s /usr/bin/batcat /usr/bin/bat

COPY --from=fetch /out/usr/share/zsh-completions/ /usr/share/zsh-completions/

# No sshd, no authorized_keys, no host keys: Tailscale SSH is the only way in,
# and it authenticates from tailnet identity plus the tailnet policy file.
COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 bootstrap-toolchain.sh devaloy-update link-shims /usr/local/bin/

# Claude Code and Codex are not installed here. mise's registry covers both and
# fetches the same upstream artifacts their own installers do, so they live in
# bootstrap-toolchain.sh with the rest of the toolchain — one package manager,
# and an upgrade that persists in the home volume instead of dying on the next
# rebuild.

# Managed dotfiles (zsh, Claude Code, Codex). entrypoint.sh copies these into
# /home/dev on every boot — see the "config sync" section of the README for
# what that overwrites and what it leaves alone. Last, because it is what
# changes most often and nothing below it needs rebuilding.
COPY config /opt/devaloy/config

# No VOLUME instruction: compose declares the named volumes, and Docker seeds an
# empty named volume from the image either way. Declaring it here would only
# force an anonymous volume on a plain `docker run`.

ENTRYPOINT ["/entrypoint.sh"]
