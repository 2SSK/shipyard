FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv openssh-server dbus sudo nginx git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN rm -f /etc/ssh/ssh_host_*_key*

RUN useradd --create-home --shell /bin/bash --groups systemd-journal deploy \
    && mkdir -p /var/www /var/log/shipyard \
    && chown deploy:deploy /var/www /var/log/shipyard \
    && chgrp deploy /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled \
    && chmod 775 /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled

COPY sshd-lab.conf /etc/ssh/sshd_config.d/lab.conf
COPY --chmod=0440 sudoers-deploy /etc/sudoers.d/deploy
COPY --chmod=0755 entrypoint.sh /usr/local/bin/lab-entrypoint

RUN visudo -c

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/bin/lab-entrypoint"]
CMD ["/sbin/init"]
