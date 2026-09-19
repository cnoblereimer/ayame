# Dashboard cert sync (ayame → michi)

See the main README's "Why the dashboard cert is synced from ayame to
michi" section for the reasoning. This directory holds the actual scripts;
this file is the one-time setup runbook. Run the ayame steps on ayame and
the michi steps on michi.

Paths below assume this repo is checked out at `/opt/pangolin-cluster` on
both hosts, matching the rest of the README - adjust if yours differs.

## 1. On michi: generate a dedicated keypair

No passphrase - this runs unattended from a systemd timer.

```bash
ssh-keygen -t ed25519 -f /opt/pangolin-cluster/cert-sync/cert-sync-key -N "" -C "michi-cert-sync"
cat /opt/pangolin-cluster/cert-sync/cert-sync-key.pub
```

Copy the printed public key - you'll need it in the next step.

## 2. On ayame: authorize that key, restricted to the sync script only

```bash
chmod +x /opt/pangolin-cluster/cert-sync/ayame/cert-sync-allowed.sh
mkdir -p /root/.ssh
echo 'command="/opt/pangolin-cluster/cert-sync/ayame/cert-sync-allowed.sh",no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty PASTE_MICHI_PUBLIC_KEY_HERE' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

Replace `PASTE_MICHI_PUBLIC_KEY_HERE` with the full `ssh-ed25519 AAAA...
michi-cert-sync` line from step 1. This key can only ever run
`cert-sync-allowed.sh`, which itself only allows reading
`config/certificates/<dashboard domain>/{cert.pem,key.pem}` - nothing else,
no shell.

## 3. On michi: do a first sync manually, then enable the timer

```bash
chmod +x /opt/pangolin-cluster/cert-sync/michi/sync-dashboard-cert.sh
/opt/pangolin-cluster/cert-sync/michi/sync-dashboard-cert.sh   # first run - accept ayame's host key when prompted

cp /opt/pangolin-cluster/cert-sync/michi/pangolin-cert-sync.service /etc/systemd/system/
cp /opt/pangolin-cluster/cert-sync/michi/pangolin-cert-sync.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pangolin-cert-sync.timer
```

## 4. Verify

```bash
systemctl list-timers pangolin-cert-sync.timer
openssl s_client -connect <MICHI_PUBLIC_IP>:443 -servername <DASHBOARD_DOMAIN> </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject
```

The second command should now show Let's Encrypt as the issuer instead of
`TRAEFIK DEFAULT CERT`.
