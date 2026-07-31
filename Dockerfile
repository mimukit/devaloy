FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        sudo \
        git \
        tmux \
        build-essential \
        curl \
        ca-certificates \
        vim \
        htop \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a default "ubuntu" user/group at 1000:1000 — drop it so
# our dev user can claim that uid/gid predictably.
RUN userdel -r ubuntu 2>/dev/null; groupdel ubuntu 2>/dev/null; \
    groupadd --gid 1000 dev \
    && useradd --uid 1000 --gid dev --create-home --shell /bin/bash dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
COPY bootstrap-toolchain.sh devaloy-update /usr/local/bin/
RUN chmod 755 /entrypoint.sh \
        /usr/local/bin/bootstrap-toolchain.sh \
        /usr/local/bin/devaloy-update

# No VOLUME instruction: compose declares the named volume for /home/dev, and
# Docker seeds an empty named volume from the image either way. Declaring it
# here would only force an anonymous volume on a plain `docker run`.

ENTRYPOINT ["/entrypoint.sh"]
