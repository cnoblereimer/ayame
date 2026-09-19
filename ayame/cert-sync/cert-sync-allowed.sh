#!/bin/bash
# Forced command for the michi cert-sync SSH key's authorized_keys entry on
# ayame (see README.md's "Why the dashboard cert is synced" section). Only
# allows reading the two dashboard cert files - nothing else, regardless of
# what the client actually asked for over SSH ($SSH_ORIGINAL_COMMAND is
# attacker/caller controlled).
set -euo pipefail

# NOT config/certificates/<DASHBOARD_DOMAIN>: Pangolin's janitor deletes that
# directory on this node too (see config/dynamic/bootstrap.yml), so syncing
# from it fails the moment the janitor gets there first. This is the same
# copy Traefik serves here.
CERT_DIR="/opt/pangolin-cluster/cert-sync/dashboard-cert"

case "${SSH_ORIGINAL_COMMAND:-}" in
    get-cert)
        exec cat "$CERT_DIR/cert.pem"
        ;;
    get-key)
        exec cat "$CERT_DIR/key.pem"
        ;;
    *)
        echo "cert-sync-allowed: command not permitted" >&2
        exit 1
        ;;
esac
