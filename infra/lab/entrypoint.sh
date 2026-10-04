#!/bin/sh
set -eu

hostkey=/etc/ssh/hostkeys/ssh_host_ed25519_key

install -d -m 0700 /etc/ssh/hostkeys
if [ ! -s "$hostkey" ]; then
    ssh-keygen -q -t ed25519 -N '' -C shipyard-lab -f "$hostkey"
fi

install -d -m 0755 -o deploy -g deploy /var/www/html
printf 'ok\n' >/var/www/html/health
chown deploy:deploy /var/www/html/health

exec /sbin/init
