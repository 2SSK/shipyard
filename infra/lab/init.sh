#!/bin/sh

#   keys          ensure the lab keypair exists, then fix its permissions
#   known-hosts   capture each lab host's identity into known_hosts
#   rotate        replace the lab keypair, revoking the old key
#   check         assert the fleet is a usable Linux deployment target

set -eu

KEYS_DIR=/keys
KEY=$KEYS_DIR/lab_key
PUB=$KEYS_DIR/lab_key.pub
KNOWN_HOSTS=$KEYS_DIR/known_hosts

ADDR=${LAB_ADDR:-127.0.0.1}

# published-port=hostname, the same pairing compose.yaml declares.
FLEET=${LAB_FLEET:-2201=shipyard-01 2202=shipyard-02 2203=shipyard-03}

log() { printf '[init] %s\n' "$*" >&2; }
die() { printf '[init] error: %s\n' "$*" >&2; exit 1; }

# The host user must own the keypair to use it with `ssh -i`.
OWNER=$(stat -c %u:%g "$KEYS_DIR")

fingerprint() { ssh-keygen -lf "$1" | cut -d' ' -f2; }

hostnames() { for p in $FLEET; do echo "${p#*=}"; done; }
ports() { for p in $FLEET; do echo "${p%%=*}"; done; }

# Built aside then moved: an interrupted run must never leave a private key
# without its public half, which would silently rotate the fleet's login.
generate_keypair() {
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" EXIT
    ssh-keygen -q -t ed25519 -N '' -C shipyard-lab -f "$tmp/lab_key"
    chmod 600 "$tmp/lab_key"
    mv "$tmp/lab_key" "$KEY"
    mv "$tmp/lab_key.pub" "$PUB"
    trap - EXIT
    rm -rf "$tmp"
}

# sshd silently ignores a key file with loose permissions.
own_keys() {
    chown "$OWNER" "$KEY" "$PUB"
    chmod 600 "$KEY"
    chmod 644 "$PUB"
}

cmd_keys() {
    if [ -f "$KEY" ] && [ -f "$PUB" ]; then
        log 'lab keypair present, reusing it'
    else
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

cmd_known_hosts() {
    for port in $(ports); do
        n=0
        until ssh-keyscan -T 2 -p "$port" "$ADDR" >/dev/null 2>&1; do
            n=$((n + 1))
            [ "$n" -ge 30 ] && die "ssh on $ADDR:$port never answered"
            sleep 1
        done
    done

    # Staged in the same directory so the rename is atomic.
    tmp=$(mktemp "$KEYS_DIR/.known_hosts.XXXXXX")
    trap "rm -f '$tmp'" EXIT
    for port in $(ports); do
        ssh-keyscan -t ed25519 -p "$port" "$ADDR" >>"$tmp" 2>/dev/null \
            || die "keyscan failed on $ADDR:$port"
    done

    want=$(hostnames | wc -l)
    got=$(cut -d' ' -f3 "$tmp" | sort -u | wc -l)
    [ "$got" -eq "$want" ] || die "expected $want distinct host keys, got $got -- hosts are sharing an identity"

    mv "$tmp" "$KNOWN_HOSTS"
    trap - EXIT
    chown "$OWNER" "$KNOWN_HOSTS"
    chmod 644 "$KNOWN_HOSTS"
    log "captured $got distinct host identities -> $KNOWN_HOSTS"
}

PROBE='
printf "hostname=%s\n" "$(hostname)"
printf "user=%s\n" "$(id -un)"
printf "systemd=%s\n" "$(systemctl is-system-running 2>/dev/null || true)"
printf "nginx=%s\n" "$(systemctl is-active nginx 2>/dev/null || true)"
printf "health=%s\n" "$(curl -fsS http://localhost/health 2>/dev/null || echo unreachable)"
if [ -w /var/www ]; then printf "www=writable\n"; else printf "www=readonly\n"; fi
# Exercises the shipped sudoers allowlist; a malformed file fails here, not three
# phases later when configure.sh tries to use it.
if sudo -n /usr/bin/systemctl show nginx.service >/dev/null 2>&1; then
    printf "sudo=granted\n"
else
    printf "sudo=denied\n"
fi
'

probe_host() {
    ssh -i "$KEY" \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o StrictHostKeyChecking=yes \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -p "$1" "deploy@$ADDR" "$PROBE" 2>/dev/null
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

cmd_check() {
    rc=0
    pass() { printf '  ok    %s\n' "$*"; }
    fail() { printf '  FAIL  %s\n' "$*" >&2; rc=1; }

    echo 'lab keypair'
    if [ -f "$KEY" ]; then
        pass "private key present, $(fingerprint "$PUB" 2>/dev/null || echo unreadable)"
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

    if [ ! -f "$KNOWN_HOSTS" ]; then
        fail "known_hosts missing ($KNOWN_HOSTS)"
        echo
        echo "Lab not ready: run 'make lab-up'."
        return 1
    fi

    # What actually matters: known_hosts matches what each host presents now.
    echo
    echo 'host identities'
    want=$(hostnames | wc -l)
    got=$(awk '{print $3}' "$KNOWN_HOSTS" | sort -u | wc -l)
    if [ "$got" -eq "$want" ]; then
        pass "known_hosts holds $got distinct identities"
    else
        fail "known_hosts holds $got identities, want $want -- hosts share a host key"
    fi
    for port in $(ports); do
        live=$(ssh-keyscan -T 3 -t ed25519 -p "$port" "$ADDR" 2>/dev/null | awk '{print $3}' | head -1)
        recorded=$(awk -v h="[$ADDR]:$port" '$1 == h {print $3}' "$KNOWN_HOSTS" | head -1)
        if [ -z "$live" ]; then
            fail "$ADDR:$port unreachable"
        elif [ "$live" = "$recorded" ]; then
            pass "$ADDR:$port identity matches known_hosts"
        else
            fail "$ADDR:$port identity does not match known_hosts -- re-run \`make lab-up\`"
        fi
    done

    # Every assertion from here runs over a real SSH session as `deploy`.
    echo
    echo 'deployment targets'
    total=$(hostnames | wc -l)
    probes=''
    reached=0
    for spec in $FLEET; do
        port=${spec%%=*}
        expected=${spec#*=}
        out=$(probe_host "$port") || out=''
        if [ -z "$out" ]; then
            fail "$expected unreachable at $ADDR:$port (ssh or host key rejected)"
            continue
        fi
        pass "$ADDR:$port reachable as $(field "$out" user)"
        reached=$((reached + 1))

        # Port-to-host mapping: proves 2201 is shipyard-01 and not a swap.
        if [ "$(field "$out" hostname)" = "$expected" ]; then
            pass "$ADDR:$port is $expected"
        else
            fail "$ADDR:$port is $(field "$out" hostname), want $expected"
        fi
        probes="$probes
$out"
    done

    # One line per invariant, reported only if it held on every host probed.
    [ -n "$probes" ] || return 1
    if [ "$reached" -lt "$total" ]; then
        fail "invariants below cover only the $reached of $total reachable hosts"
    fi
    across() {
        key=$1 expected=$2 label=$3
        seen=$(printf '%s\n' "$probes" | grep "^$key=" | sed "s/^$key=//" | sort -u | tr '\n' ' ' | sed 's/ $//')
        if [ -z "$seen" ]; then
            fail "$key was not reported by the remote probe"
        elif [ "$seen" != "$expected" ]; then
            fail "$label (saw: $seen)"
        else
            pass "$label"
        fi
    }

    across user deploy 'deploy user'
    across systemd running 'systemd is running, readable unprivileged over SSH'
    across nginx active 'nginx is active'
    across health ok 'GET /health returns ok'
    across www writable '/var/www is writable by deploy'
    across sudo granted 'sudo systemctl/nginx allowlist applies'

    echo
    if [ "$rc" -eq 0 ]; then
        echo 'Lab read.'
    else
        echo 'Lab not ready.' >&2
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
