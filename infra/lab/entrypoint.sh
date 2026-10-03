#!/bin/sh
set -eu

hostkey=/etc/ssh/hostkeys/ssh_host_ed25519_key

install -d -m 0700 /etc/ssh/hostkeys
if [ ! -s "$hostkey" ]; then
    ssh-keygen -q -t ed25519 -N '' -C shipyard-lab -f "$hostkey"
fi

exec /sbin/init
