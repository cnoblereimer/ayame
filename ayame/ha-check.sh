#!/bin/bash
# HA smoke test for the two-node cluster.
#
# Checks every hostname three ways: through the load balancer, and pinned
# to each node directly. The pinned checks are the important ones - they
# catch a resource that is only homed on one node, which the load-balanced
# check hides roughly half the time and which is exactly how a silent
# single-homed resource went unnoticed here before.
#
# Usage: ha-check.sh [requests-per-check]   (default 10)
set -uo pipefail

DASHBOARD="<DASHBOARD_DOMAIN>"
RESOURCES=("<RESOURCE_DOMAIN>") # add EVERY resource hostname here
AYAME_IP="<AYAME_PUBLIC_IP>"
MICHI_IP="<MICHI_PUBLIC_IP>"
SOCK="${HAPROXY_SOCK:-/opt/pangolin-cluster/haproxy/run/admin.sock}"

n="${1:-10}"
failures=0

lb_failures=0
pinned_only_failures=0

probe() { # host, label, [resolve-ip]
    local host="$1" label="$2" ip="${3:-}" args=() bad=0 codes=""
    [ -n "$ip" ] && args+=(--resolve "$host:443:$ip")
    for _ in $(seq 1 "$n"); do
        # curl already prints 000 via -w when it fails to connect, so this
        # must not add a fallback of its own or the codes come out doubled.
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "${args[@]}" "https://$host/")
        codes+="$code "
        # An auth-protected resource answers 401/403 to an unauthenticated
        # probe - that is the badger middleware working, and proves this
        # node routes the hostname. The failures that matter look different:
        # 404 = no router (resource not homed on this node), 503 = no
        # reachable target, 000 = node down.
        case "$code" in
            2* | 3* | 401 | 403) ;;
            *) bad=$((bad + 1)) ;;
        esac
    done
    if [ "$bad" -eq 0 ]; then
        printf '  ok    %-28s %s\n' "$label" "$n/$n"
    else
        printf '  FAIL  %-28s %d/%d bad: %s\n' "$label" "$bad" "$n" "$codes"
        failures=$((failures + 1))
        if [ -z "$ip" ]; then
            lb_failures=$((lb_failures + 1))
        else
            pinned_only_failures=$((pinned_only_failures + 1))
        fi
    fi
}

ayame_state="unknown"
michi_state="unknown"

echo "haproxy backend state:"
if [ -S "$SOCK" ]; then
    stats=$(printf 'show stat\n' | socat stdio "UNIX-CONNECT:$SOCK")
    echo "$stats" |
        awk -F, '$1 ~ /_back$/ && $2 !~ /BACKEND|FRONTEND/ && $2 != "" { print "  " $1 "/" $2 ": " $18 }'
    # websecure_back is the one that matters for these probes
    ayame_state=$(echo "$stats" | awk -F, '$1=="websecure_back" && $2=="ayame" { print $18 }')
    michi_state=$(echo "$stats" | awk -F, '$1=="websecure_back" && $2=="michi" { print $18 }')
else
    echo "  (runtime socket not available at $SOCK)"
fi

# A node that is drained or already down is *expected* to fail its pinned
# probe - reporting that as a failure buries the one result that matters
# (whether the load balancer still serves everything) under noise, and
# points at dual-homing, which is not the problem.
pinned() { # host, node-label, ip, state
    case "$4" in
        UP*) probe "$1" "pinned to $2" "$3" ;;
        *) printf '  skip  %-28s node is %s\n' "pinned to $2" "${4:-unreachable}" ;;
    esac
}

for host in "$DASHBOARD" "${RESOURCES[@]}"; do
    echo
    echo "$host:"
    probe "$host" "via load balancer"
    pinned "$host" "ayame" "$AYAME_IP" "$ayame_state"
    pinned "$host" "michi" "$MICHI_IP" "$michi_state"
done

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
    if [ "$lb_failures" -gt 0 ]; then
        echo "the load balancer itself failed, so this is not about which node"
        echo "serves what - the same failure on both nodes usually means the"
        echo "resource's target is unreachable (503 from Traefik = no server"
        echo "available) or the site's tunnel is down."
    elif [ "$pinned_only_failures" -gt 0 ]; then
        echo "a hostname that passes through the load balancer but fails pinned"
        echo "to one node is served by only that node - it needs a target on"
        echo "both sites (see README, \"Rolling pangolin updates\")."
    fi
fi
exit "$failures"
