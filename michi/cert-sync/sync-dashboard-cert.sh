#!/bin/bash
# Pulls the dashboard domain's real cert/key from ayame and installs them
# atomically into michi's local certificate directory, where
# michi/config/dynamic/bootstrap.yml's hand-written tls.certificates entry
# expects to find them. Traefik reloads a referenced cert file automatically
# whenever its content changes, so this script never needs to touch
# bootstrap.yml or restart anything - it only ever rewrites cert.pem/key.pem.
# See the repo's top-level README.md, "Why the dashboard cert is synced
# from ayame to michi", for what this depends on and why it exists.
set -euo pipefail

SSH_KEY="/opt/pangolin-cluster/cert-sync/cert-sync-key"
AYAME_HOST="<AYAME_SSH_USER>@<AYAME_PUBLIC_IP>"
AYAME_SSH_PORT="<AYAME_SSH_PORT>"
DEST_DIR="/opt/pangolin-cluster/config/certificates/<DASHBOARD_DOMAIN>"

mkdir -p "$DEST_DIR"

cert_tmp=$(mktemp "$DEST_DIR/.cert.pem.tmp.XXXXXX")
key_tmp=$(mktemp "$DEST_DIR/.key.pem.tmp.XXXXXX")
cleanup() { rm -f "$cert_tmp" "$key_tmp"; }
trap cleanup EXIT

ssh -i "$SSH_KEY" -p "$AYAME_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new "$AYAME_HOST" get-cert >"$cert_tmp"
ssh -i "$SSH_KEY" -p "$AYAME_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new "$AYAME_HOST" get-key >"$key_tmp"

if [ ! -s "$cert_tmp" ] || [ ! -s "$key_tmp" ]; then
    echo "sync-dashboard-cert: refusing to install an empty cert or key" >&2
    exit 1
fi

chmod 644 "$cert_tmp"
chmod 600 "$key_tmp"
mv "$cert_tmp" "$DEST_DIR/cert.pem"
mv "$key_tmp" "$DEST_DIR/key.pem"
trap - EXIT

echo "sync-dashboard-cert: updated $DEST_DIR/{cert,key}.pem"
