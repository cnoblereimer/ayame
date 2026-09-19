# Pangolin two-node cluster (ayame + michi)

This repo holds the deployment for a two-node [Pangolin](https://github.com/fosrl/pangolin) EE
cluster:

- **ayame** — shared Postgres + Redis, HAProxy, and a Pangolin cluster node
  (`pangolin` + `gerbil` + `traefik`). Files live at the repo root.
- **michi** — a second Pangolin cluster node only. Files live under `michi/`
  and should be copied to that host.

Clustering (shared database, multiple `pangolin`/`gerbil`/`traefik` nodes) is
an Enterprise Edition feature — both nodes run
`fosrl/pangolin:ee-postgresql-latest` and require a valid EE license.

**Important:** use the `ee-postgresql-*` tag family, not plain `ee-latest`.
`ee-latest` is built against the SQLite code path (its bundled
`dist/migrations.mjs` and `dist/init/*.sql` are SQLite DDL — backtick-quoted
identifiers, `AUTOINCREMENT`, etc.) and will never create a working Postgres
schema, even though the app otherwise happily connects to Postgres for
everything else. Confirmed by pulling the `ee-latest` image directly: its
migration runner's SQLite-specific error handling
(`SqliteError`/`SQLITE_CONSTRAINT_UNIQUE`) is compiled into a file that's
supposed to run Postgres migrations, and it never actually creates any
tables against a real Postgres database. `ee-postgresql-latest` is the
correctly-built variant for this setup.

## Topology

Ayame and michi only see each other over the **public internet** in this
setup, so:

- Postgres (`5432`) and Redis (`6379`) are published on ayame's public IP so
  michi's `pangolin` container can reach them. **Firewall these to only
  accept connections from michi's IP** (e.g. `ufw allow from <MICHI_PUBLIC_IP>
  to any port 5432,6379,3004 proto tcp`), then deny them from everywhere
  else — these ports and the gerbil control API should never be open to the
  public internet.
- HAProxy on ayame owns ports `80`, `443`, and `3000` (dashboard) on the
  host and round-robins TCP connections across both nodes: ayame's own
  `gerbil`/`traefik` (reached over the internal `pangolin` docker network)
  and michi's `gerbil`/`traefik` (reached over the public internet on the
  ports michi publishes). Pangolin/traefik terminate TLS themselves, so
  HAProxy just passes TCP through — no certs needed on the load balancer.
- WireGuard (`51820/udp`), the relay (`21820/udp`), and DNS (`53/udp`) are
  **not** load balanced — each node is its own WireGuard exit node, so
  clients/sites connect to whichever node's public IP they're configured
  for directly.
- The gerbil control API (`3004/tcp`) is published on both hosts so the two
  nodes can talk to each other directly; it does not go through HAProxy.

## Placeholders to fill in before deploying

| Placeholder | Where | Value |
|---|---|---|
| `<AYAME_PUBLIC_IP>` | `config/config.yml`, `docker-compose.yml`, `haproxy/haproxy.cfg`, `michi/config/*` | ayame's public IP |
| `<MICHI_PUBLIC_IP>` | `michi/config/config.yml`, `michi/docker-compose.yml`, `config/config.yml`, `docker-compose.yml`, `haproxy/haproxy.cfg` | michi's public IP |
| `<CLUSTER_SECRET>` | `config/config.yml`, `michi/config/config.yml` | same random value on **both** nodes — generate once with `openssl rand -hex 32` |
| `<CONTACT_EMAIL>` | `config/privateConfig.yml`, `michi/config/privateConfig.yml` | email for ACME/Let's Encrypt |
| `POSTGRES_PASSWORD` | `.env` (copy from `.env.example`) and `michi/config/config.yml`'s connection string | shared DB password |
| `pangolin.example.com` | `config/config.yml`, `michi/config/config.yml` | your real dashboard domain |
| `<DASHBOARD_DOMAIN>` | `config/dynamic/bootstrap.yml`, `michi/config/dynamic/bootstrap.yml` | same domain as `dashboard_url`, without the scheme |

## Deploy order

1. On **ayame**: copy `.env.example` to `.env`, fill in `POSTGRES_PASSWORD`,
   fill in all placeholders above, drop `GeoLite2-Country.mmdb` /
   `GeoLite2-ASN.mmdb` into `config/`, then `docker compose up -d`.
2. Open the firewall rules noted above so michi can reach ayame's Postgres,
   Redis, and gerbil control API.
3. On **michi**: copy the `michi/` directory to the host (as its own compose
   project root), fill in its placeholders (same `<CLUSTER_SECRET>` and
   `POSTGRES_PASSWORD` as ayame), drop the GeoLite2 databases into
   `config/`, then `docker compose up -d`.
4. Point DNS for your dashboard/resource domains at ayame's HAProxy (or at
   both nodes' IPs via round-robin DNS, if you don't want a single point of
   ingress).

## Why `config/dynamic/bootstrap.yml` exists

Pangolin never generates a Traefik router for its own admin dashboard —
only for per-resource "login pages", and those require a DB row that
normally gets created *through the dashboard itself* (a chicken-and-egg gap,
confirmed by reading `getTraefikConfig.ts`'s `generateLoginPageRouters`
logic). Without this file, the dashboard domain 404s on Traefik forever,
even after initial setup. `bootstrap.yml` is a hand-written Traefik dynamic
config (picked up live via the `file` provider, no restart needed) that
routes `/api/v1/*` to Pangolin's Dashboard API (`pangolin:3000`) and
everything else to its Web UI (`pangolin:3002`), bypassing Pangolin's own
router generation entirely for this one host. It needs to exist identically
on **both** nodes, since HAProxy round-robins dashboard traffic across
ayame and michi.

Until a real domain/resource is configured with a valid ACME cert, this
domain serves Traefik's self-signed fallback certificate — click through
your browser's warning (and clear any cached HSTS policy for the domain via
`about:networking#hsts` in Firefox if it refuses to let you).

## Source

Adapted from Pangolin's official [HA reference
config](https://github.com/fosrl/pangolin/tree/main/config/ha-reference) and
[clustering docs](https://docs.pangolin.net/self-host/clustering/deploy-a-cluster).
