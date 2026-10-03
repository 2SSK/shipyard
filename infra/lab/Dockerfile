FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  systemd systemd-sysv openssh-server sudo nginx git curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --groups systemd-journal deploy \
  && mkdir -p /var/www /var/log/shipyard \
  && chown deploy:deploy /var/www /var/log/shipyard \
  && chgrp deploy /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled \
  && chmod 775 /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled

COPY <<EOF /etc/ssh/sshd_config.d/lab.conf
AllowUsers deploy
PasswordAuthentication no
AuthorizedKeysCommand /usr/bin/cat /keys/lab_key.pub
AuthorizedKeysCommandUser nobody
EOF

COPY --chmod=0440 <<'EOF' /etc/sudoers.d/deploy
Cmnd_Alias SHIPYARD = /usr/bin/systemctl daemon-reload, \
  /usr/bin/systemctl start *, /usr/bin/systemctl stop *, \
  /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, \
  /usr/bin/systemctl enable *, /usr/bin/systemctl disable *, \
  /usr/bin/systemctl show *, /usr/sbin/nginx -t
deploy ALL=(root) NOPASSWD: SHIPYARD
EOF

RUN visudo -c

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
