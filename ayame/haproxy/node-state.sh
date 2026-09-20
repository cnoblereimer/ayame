#!/bin/bash
# Drain a cluster node out of haproxy before updating it, and put it back
# after. Wraps the runtime API so the socat address type is never omitted:
# a bare path makes socat create a regular FILE over the socket, after
# which haproxy cannot rebind it and crash-loops, taking 443 down.
#
# Usage: node-state.sh <ayame|michi> <maint|ready>
set -euo pipefail

SOCK="${HAPROXY_SOCK:-/opt/pangolin-cluster/haproxy/run/admin.sock}"
node="${1:-}"
state="${2:-}"

usage() { echo "usage: $0 <ayame|michi> <maint|ready>" >&2; exit 1; }

case "$node" in ayame | michi) ;; *) usage ;; esac
case "$state" in maint | ready) ;; *) usage ;; esac

if [ ! -S "$SOCK" ]; then
    echo "node-state: $SOCK is not a unix socket - refusing to touch it" >&2
    exit 1
fi

send() { printf '%s\n' "$1" | socat stdio "UNIX-CONNECT:$SOCK"; }

# All three backends, so a node going down is fully out of rotation - not
# just for HTTPS.
for backend in web_back websecure_back dashboard_back; do
    send "set server $backend/$node state $state" >/dev/null
done

echo "node-state: $node -> $state"
send "show stat" | awk -F, -v n="$node" '$2 == n { print "  " $1 "/" $2 ": " $18 }'
