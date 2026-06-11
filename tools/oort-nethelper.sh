#!/bin/sh
# oort privileged network helper (M9) — the root half of sudo-free networking.
#
# Installed once (root-owned, sudo) to /Library/PrivilegedHelperTools and run by
# a LaunchDaemon that watches ONE user-writable request file. The user side
# (the oort CLI) writes a one-line request; this script validates it strictly
# and applies exactly two kinds of privileged state, nothing else:
#
#   up <gateway-ip> <dns-port>   route 172.17.0.0/16 via <gateway-ip>
#                                + /etc/resolver/oort.local → 127.0.0.1:<dns-port>
#   down                         remove both
#
# The request file content is attacker-writable by design (it lives in the
# user's home), so EVERYTHING is validated against fixed patterns and all
# writes go to fixed root-owned paths. No part of the request is ever
# executed or interpolated into a command unvalidated.
set -u

REQ="${OORT_NET_REQUEST:?}"          # baked into the LaunchDaemon plist
STATUS="${REQ}.status"               # result note for the user side
RESOLVER=/etc/resolver/oort.local
SUBNET=172.17.0.0/16                 # docker bridge
K8SNET=10.43.0.0/16                  # k3s ClusterIP range (kube-proxy on the guest forwards)

note() { echo "$(date '+%H:%M:%S') $*" > "$STATUS" 2>/dev/null || true; }

[ -f "$REQ" ] || exit 0
# Read at most one small line; ignore anything bigger (defense in depth).
line=$(head -c 64 "$REQ" | head -n 1)

case "$line" in
  up\ *)
    gw=$(echo "$line" | awk '{print $2}')
    port=$(echo "$line" | awk '{print $3}')
    # VZ NAT guest IPs are always 192.168.x.x; the resolver port is unprivileged.
    echo "$gw"   | grep -Eq '^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$' || { note "rejected gateway '$gw'"; exit 0; }
    echo "$port" | grep -Eq '^[0-9]{4,5}$' || { note "rejected port '$port'"; exit 0; }
    [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || { note "rejected port $port"; exit 0; }
    route -n delete -net "$SUBNET" >/dev/null 2>&1
    route -n add -net "$SUBNET" "$gw" >/dev/null 2>&1 || { note "route add failed"; exit 0; }
    route -n delete -net "$K8SNET" >/dev/null 2>&1
    route -n add -net "$K8SNET" "$gw" >/dev/null 2>&1
    mkdir -p /etc/resolver
    printf 'nameserver 127.0.0.1\nport %s\n' "$port" > "$RESOLVER"
    note "up: $SUBNET + $K8SNET via $gw, resolver port $port"
    ;;
  down)
    route -n delete -net "$SUBNET" >/dev/null 2>&1
    route -n delete -net "$K8SNET" >/dev/null 2>&1
    rm -f "$RESOLVER"
    note "down: routes + resolver removed"
    ;;
  *)
    note "rejected request"
    ;;
esac
exit 0
