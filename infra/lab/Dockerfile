# A lab target host: Ubuntu running real systemd, sshd and nginx, reachable over
# SSH. Stands in for an Ubuntu VPS -- the engine talks to it over real SSH and
# knows nothing about Docker, so the same code path serves a VPS in Phase 6.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# dbus is not optional here. Without it /run/systemd/private is root-only and
# unprivileged `systemctl` over SSH fails with "Failed to connect to bus", which
# a real VPS does not do. Shipping it keeps the lab honest about how the engine
# will read host state.
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv openssh-server dbus sudo nginx git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# An image that ships host keys hands its private keys to anyone who pulls it,
# and makes every container built from it indistinguishable. Each lab server
# generates its own on first boot instead -- see entrypoint.sh.
RUN rm -f /etc/ssh/ssh_host_*_key*

RUN useradd --create-home --shell /bin/bash --groups systemd-journal deploy \
    && mkdir -p /var/www /var/log/shipyard \
    && chown deploy:deploy /var/www /var/log/shipyard \
    && chgrp deploy /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled \
    && chmod 775 /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled

# Configuration lives in real files, not Dockerfile heredocs, so it can be read,
# diffed and linted on its own.
COPY sshd-lab.conf /etc/ssh/sshd_config.d/lab.conf
COPY --chmod=0440 sudoers-deploy /etc/sudoers.d/deploy
COPY --chmod=0755 entrypoint.sh /usr/local/bin/lab-entrypoint

# Fails the build on a malformed sudoers file rather than at deploy time.
RUN visudo -c

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/bin/lab-entrypoint"]
CMD ["/sbin/init"]
