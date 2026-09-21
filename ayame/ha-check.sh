#!/bin/bash
# HA smoke test for the two-node cluster. Run it from either node - it
# needs the inter-node tunnel to probe each node directly.
#
# Every hostname is checked three ways:
#
#   via DNS      - whatever a real client gets, across both load balancers
#   ingress <n>  - that node's haproxy on its public IP
#   node <n>     - that node's OWN traefik, gerbil-direct over the tunnel
#
# The last one matters most. Both load balancers can serve from either
# node, so "ingress michi" passes even when michi's own stack is broken and
# its haproxy is quietly serving everything from ayame. Only the
# gerbil-direct probe separates "this node works" from "this node's load
# balancer works" - and it is what catches a resource homed on just one
# node, the failure that hid here for a long time.
#
# Usage: ha-check.sh [requests-per-check]   (default 10)
set -uo pipefail

DASHBOARD="<DASHBOARD_DOMAIN>"
# Add EVERY resource hostname here, and to urad/docker-compose.yml's
# RESOURCES, whenever a resource is created.
RESOURCES=("<RESOURCE_DOMAIN>")
AYAME_IP="<AYAME_PUBLIC_IP>"
MICHI_IP="<MICHI_PUBLIC_IP>"
AYAME_WG="10.88.0.1"
MICHI_WG="10.88.0.2"
GERBIL_TLS_PORT="8444" # traefik's websecure, published on the tunnel only
SOCK="${HAPROXY_SOCK:-/opt/pangolin-cluster/haproxy/run/admin.sock}"

n="${1:-10}"
failures=0
dns_failures=0
other_failures=0

probe() { # label, host, curl-args...
    local label="$1" host="$2"
    shift 2
    local bad=0 codes="" code
    for _ in $(seq 1 "$n"); do
        # curl already prints 000 via -w when it cannot connect, so this
        # must not add a fallback of its own or the codes come out doubled.
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "https://$host/")
        codes+="$code "
        # An auth-protected resource answers 401/403 to an unauthenticated
        # probe - that is the badger middleware working, and proves the
        # hostname routed. The failures that matter look different: 404 =
        # no router (not homed here), 503 = no reachable target, 000 = down.
        case "$code" in
            2* | 3* | 401 | 403) ;;
            *) bad=$((bad + 1)) ;;
        esac
    done
    if [ "$bad" -eq 0 ]; then
        printf '  ok    %-22s %s\n' "$label" "$n/$n"
    else
        printf '  FAIL  %-22s %d/%d bad: %s\n' "$label" "$bad" "$n" "$codes"
        failures=$((failures + 1))
        case "$label" in
            "via DNS") dns_failures=$((dns_failures + 1)) ;;
            *) other_failures=$((other_failures + 1)) ;;
        esac
    fi
}

echo "haproxy backend state (this node's load balancer):"
if [ -S "$SOCK" ]; then
    printf 'show stat\n' | socat stdio "UNIX-CONNECT:$SOCK" |
        awk -F, '$1 ~ /_back$/ && $2 !~ /BACKEND|FRONTEND/ && $2 != "" { print "  " $1 "/" $2 ": " $18 }'
else
    echo "  (runtime socket not available at $SOCK)"
fi

for host in "$DASHBOARD" "${RESOURCES[@]}"; do
    echo
    echo "$host:"
    probe "via DNS" "$host"
    probe "ingress ayame" "$host" --resolve "$host:443:$AYAME_IP"
    probe "ingress michi" "$host" --resolve "$host:443:$MICHI_IP"
    # --connect-to keeps the Host header and SNI intact while connecting to
    # the node's gerbil port over the tunnel, bypassing both load balancers.
    probe "node ayame" "$host" --connect-to "$host:443:$AYAME_WG:$GERBIL_TLS_PORT"
    probe "node michi" "$host" --connect-to "$host:443:$MICHI_WG:$GERBIL_TLS_PORT"
done

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
    if [ "$dns_failures" -gt 0 ] && [ "$other_failures" -eq 0 ]; then
        echo "only the DNS path failed while both nodes serve directly - suspect"
        echo "the records themselves (a missing dns.static_records entry, or a"
        echo "resolver holding a node that is down)."
    elif [ "$other_failures" -gt 0 ]; then
        echo "a hostname that fails 'node <x>' but passes 'ingress <x>' is not"
        echo "homed on that node - its load balancer is covering by serving from"
        echo "the peer. Give the resource a target on that node's site (see"
        echo "README, \"Rolling pangolin updates\"). A node failing everything is"
        echo "simply down or draining."
    fi
fi
exit "$failures"
