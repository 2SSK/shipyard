#!/bin/sh
# Shipyard lab init container.
#
#   keys          ensure the lab keypair exists, then fix its permissions
#   known-hosts   capture each lab host's identity into known_hosts
#   rotate        replace the lab keypair, revoking the old key
#   check         assert the fleet's SSH invariants; non-zero on failure
#
# Every command converges on the desired state rather than assuming a clean
# slate, so running it twice is a no-op. `keys` and `rotate` run with no network
# (they only touch ./keys); `known-hosts` and `check` need host networking to
# reach the fleet's published ports.
set -eu

KEYS_DIR=/keys
KEY=$KEYS_DIR/lab_key
PUB=$KEYS_DIR/lab_key.pub
KNOWN_HOSTS=$KEYS_DIR/known_hosts

# Published SSH ports of the lab fleet, in fleet order.
PORTS=${LAB_PORTS:-2201 2202 2203}

log() { printf '[init] %s\n' "$*" >&2; }
die() { printf '[init] error: %s\n' "$*" >&2; exit 1; }

# The bind mount belongs to the host user, who needs to own the pair to use it
# with `ssh -i`. Captured once, at start.
OWNER=$(stat -c %u:%g "$KEYS_DIR")

fingerprint() { ssh-keygen -lf "$1" | cut -d' ' -f2; }

# Generated into a scratch directory first so the pair appears atomically: an
# interrupted run must never leave a private key without its public half, which
# would silently rotate the fleet's login on the next `up`.
generate_keypair() {
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  ssh-keygen -q -t ed25519 -N '' -C shipyard-lab -f "$tmp/lab_key"
  chmod 600 "$tmp/lab_key"
  mv "$tmp/lab_key" "$KEY"
  mv "$tmp/lab_key.pub" "$PUB"
  trap - EXIT
  rm -rf "$tmp"
}

# sshd silently ignores a key file with loose permissions, and the host user
# must own it -- both failures are invisible until a login is refused.
own_keys() {
  chown "$OWNER" "$KEY" "$PUB"
  chmod 600 "$KEY"
  chmod 644 "$PUB"
}

cmd_keys() {
  if [ -f "$KEY" ] && [ -f "$PUB" ]; then
    log 'lab keypair present, reusing it'
  else
    # A half-present pair means an interrupted earlier run; regenerate rather
    # than hand sshd a private key with no matching public half.
    log 'lab keypair missing or incomplete, generating one'
    generate_keypair
  fi
  own_keys
  log "ready: $(fingerprint "$PUB")"
}

cmd_rotate() {
  log 'rotating lab keypair'
  generate_keypair
  own_keys
  log "new key: $(fingerprint "$PUB")"
  log 'sshd reads the public key at login, so the new key works on the next'
  log 'connection. Sessions already open keep the old key until they close.'
}

# Runs after the fleet reports healthy. Each host presents its own host key, so
# this captures three distinct identities -- which is the entire point of having
# per-server host keys at all.
cmd_known_hosts() {
  for port in $PORTS; do
    n=0
    until ssh-keyscan -T 2 -p "$port" localhost >/dev/null 2>&1; do
      n=$((n + 1))
      [ "$n" -ge 30 ] && die "ssh on port $port never answered"
      sleep 1
    done
  done

  # Same directory as the target, so the rename is atomic and readers never see
  # a half-written file.
  tmp=$(mktemp "$KEYS_DIR/.known_hosts.XXXXXX")
  # shellcheck disable=SC2064  # $tmp must be captured now, not at trap time
  trap "rm -f '$tmp'" EXIT
  for port in $PORTS; do
    ssh-keyscan -t ed25519 -p "$port" localhost >>"$tmp" 2>/dev/null \
      || die "keyscan failed on port $port"
  done

  # A capture that collapsed to one identity means the fleet is sharing a host
  # key, and known_hosts has quietly stopped verifying anything. Refuse it.
  want=$(echo "$PORTS" | wc -w)
  got=$(cut -d' ' -f3 "$tmp" | sort -u | wc -l)
  [ "$got" -eq "$want" ] || die "expected $want distinct host keys, got $got -- hosts are sharing an identity"

  mv "$tmp" "$KNOWN_HOSTS"
  trap - EXIT
  chown "$OWNER" "$KNOWN_HOSTS"
  chmod 644 "$KNOWN_HOSTS"
  log "captured $got distinct host identities -> $KNOWN_HOSTS"
}

# The acceptance test for Phase 0, as code. Phase 5's fault-injection loop calls
# this instead of re-running commands from the roadmap.
cmd_check() {
  rc=0
  pass() { printf '  ok    %s\n' "$*"; }
  fail() { printf '  FAIL  %s\n' "$*" >&2; rc=1; }

  echo 'lab keypair'
  if [ -f "$KEY" ]; then
    pass 'private key present'
    mode=$(stat -c %a "$KEY")
    if [ "$mode" = 600 ]; then
      pass 'private key is 0600'
    else
      fail "private key is $mode, want 600"
    fi
  else
    fail "private key missing ($KEY)"
  fi

  if [ -f "$PUB" ]; then
    pass 'public key present'
  else
    fail "public key missing ($PUB)"
  fi

  echo 'known_hosts'
  if [ ! -f "$KNOWN_HOSTS" ]; then
    fail "known_hosts missing ($KNOWN_HOSTS)"
  else
    want=$(echo "$PORTS" | wc -w)
    got=$(awk '{print $3}' "$KNOWN_HOSTS" | sort -u | wc -l)
    if [ "$got" -eq "$want" ]; then
      pass "holds $got distinct identities"
    else
      fail "holds $got identities, want $want -- hosts are sharing a host key"
    fi

    # The assertion that actually matters: what known_hosts claims is what each
    # host presents right now.
    for port in $PORTS; do
      live=$(ssh-keyscan -T 3 -t ed25519 -p "$port" localhost 2>/dev/null | awk '{print $3}' | head -1)
      recorded=$(awk -v h="[localhost]:$port" '$1 == h {print $3}' "$KNOWN_HOSTS" | head -1)
      if [ -z "$live" ]; then
        fail "port $port unreachable"
      elif [ "$live" = "$recorded" ]; then
        pass "port $port identity matches known_hosts"
      else
        fail "port $port identity does not match known_hosts"
      fi
    done
  fi

  if [ "$rc" -eq 0 ]; then
    echo 'lab ssh: all checks passed'
  fi
  return "$rc"
}

case "${1:-keys}" in
  keys) cmd_keys ;;
  known-hosts) cmd_known_hosts ;;
  rotate) cmd_rotate ;;
  check) cmd_check ;;
  *) die "unknown command '$1' (expected keys, known-hosts, rotate or check)" ;;
esac
