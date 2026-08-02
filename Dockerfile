FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/* \
    # Ubuntu ships bat as `batcat` to avoid a name clash with bacula-console.
    # Link it in /usr/bin, not /usr/local/bin — link-shims owns the latter and
    # will overwrite a symlink it finds there.
    && ln -s /usr/bin/batcat /usr/bin/bat

# tailscaled lives *inside* this image on purpose. Tailscale SSH terminates the
# connection in whichever container runs tailscaled and spawns the shell there —
# so a sidecar sharing only the network namespace would drop you into the
# sidecar's filesystem, not this one. See tailscale/tailscale#5215.
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a default "ubuntu" user/group at 1000:1000 — drop it so
# our dev user can claim that uid/gid predictably.
# The login shell is read from /etc/passwd, which lives in this image rather
# than the home volume — so zsh is the shell Tailscale SSH spawns from the
# first boot onward, with no chsh needed on the box.
RUN userdel -r ubuntu 2>/dev/null; groupdel ubuntu 2>/dev/null; \
    groupadd --gid 1000 dev \
    && useradd --uid 1000 --gid dev --create-home --shell /usr/bin/zsh dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev

# No sshd, no authorized_keys, no host keys: Tailscale SSH is the only way in,
# and it authenticates from tailnet identity plus the tailnet policy file.
COPY entrypoint.sh /entrypoint.sh
COPY bootstrap-toolchain.sh devaloy-update link-shims /usr/local/bin/
RUN chmod 755 /entrypoint.sh \
        /usr/local/bin/bootstrap-toolchain.sh \
        /usr/local/bin/devaloy-update \
        /usr/local/bin/link-shims

# Claude Code and Codex are not installed here. mise's registry covers both and
# fetches the same upstream artifacts their own installers do, so they live in
# bootstrap-toolchain.sh with the rest of the toolchain — one package manager,
# and an upgrade that persists in the home volume instead of dying on the next
# rebuild.

# Managed dotfiles (zsh, Claude Code, Codex). entrypoint.sh copies these into
# /home/dev on every boot — see the "config sync" section of the README for
# what that overwrites and what it leaves alone.
COPY config /opt/devaloy/config

# No VOLUME instruction: compose declares the named volumes, and Docker seeds an
# empty named volume from the image either way. Declaring it here would only
# force an anonymous volume on a plain `docker run`.

ENTRYPOINT ["/entrypoint.sh"]
