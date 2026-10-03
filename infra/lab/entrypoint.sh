#!/bin/sh
# Lab host entrypoint: give this server its own SSH host key, then hand PID 1
# to systemd.
#
# This mirrors what sshd does on a freshly booted VPS -- identity is created on
# first boot and then persists. The key lives on a named volume, so `compose
# down` keeps it and known_hosts stays valid; only `down -v` rotates it.
set -eu

hostkey=/etc/ssh/hostkeys/ssh_host_ed25519_key

install -d -m 0700 /etc/ssh/hostkeys
if [ ! -s "$hostkey" ]; then
  ssh-keygen -q -t ed25519 -N '' -C shipyard-lab -f "$hostkey"
fi

exec /sbin/init
