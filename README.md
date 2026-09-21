# Pangolin two-node cluster (ayame + michi)

This repo holds the deployment for a two-node [Pangolin](https://github.com/fosrl/pangolin) EE
cluster, one self-contained folder per host:

- **`ayame/`** — shared Postgres + Redis, HAProxy, and a Pangolin cluster
  node (`pangolin` + `gerbil` + `traefik`). Copy this whole folder's
  *contents* to ayame's deployment directory.
- **`michi/`** — a second Pangolin cluster node only. Copy this whole
  folder's *contents* to michi's deployment directory.

Each folder is a complete `docker compose` project root on its own — no
file lives outside these two folders except this README and top-level
`.gitignore`, so deploying a host is just "copy its folder over."

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

Ayame and michi have no shared private network of their own, so one is
built: a **WireGuard link on `10.88.0.0/30`** carries everything that
passes between them (see "Private network between the nodes").

- Postgres (`5432`) and Redis (`6379`) run on ayame and are published on
  its **tunnel address only** (`10.88.0.1`), never a public interface.
  Redis additionally requires a password.
- **Both nodes run HAProxy**, each owning `80`, `443` and `3000` on its own
  host and each able to serve from either node: its own `gerbil`/`traefik`
  over the internal `pangolin` docker network, and the peer's over the
  tunnel. Every hostname has an `A` record for both nodes, so clients
  spread across the two and neither is a single point of ingress.
  Pangolin/traefik terminate TLS themselves, so HAProxy just passes TCP
  through — no certs on the load balancers.
- **A load balancer reaches the peer at its *gerbil* ports**
  (`10.88.0.x:8080/8444/8300`, published on the tunnel only), never at the
  peer's public `80/443/3000`. Those belong to the peer's HAProxy, and
  pointing one load balancer at the other lets a request bounce between
  them indefinitely.
- The gerbil control API (`3004/tcp`) is still published publicly on both
  hosts, because Pangolin records each node's `reachableAt` as a public
  URL. Firewall it to the peer's IP.
- WireGuard (`51820/udp`), the relay (`21820/udp`), and DNS (`53/udp`) are
  **not** load balanced — each node is its own WireGuard exit node, so
  clients/sites connect to whichever node's public IP they're configured
  for directly.

## Placeholders to fill in before deploying

| Placeholder | Where | Value |
|---|---|---|
| `<AYAME_PUBLIC_IP>` | `ayame/config/config.yml`, `ayame/docker-compose.yml`, `ayame/haproxy/haproxy.cfg`, `ayame/cert-sync/*`, `michi/config/*`, `michi/cert-sync/*` | ayame's public IP |
| `<MICHI_PUBLIC_IP>` | `michi/config/config.yml`, `michi/docker-compose.yml`, `ayame/config/config.yml`, `ayame/docker-compose.yml`, `ayame/haproxy/haproxy.cfg` | michi's public IP |
| `<CLUSTER_SECRET>` | `ayame/config/config.yml`, `michi/config/config.yml` | same random value on **both** nodes — generate once with `openssl rand -hex 32` |
| `<CONTACT_EMAIL>` | `ayame/config/privateConfig.yml`, `michi/config/privateConfig.yml` | email for ACME/Let's Encrypt |
| `POSTGRES_PASSWORD` | `ayame/.env` (copy from `ayame/.env.example`) and `michi/config/config.yml`'s connection string | shared DB password |
| `REDIS_PASSWORD` | `ayame/.env` **and** `michi/.env` (copy from each `.env.example`) | must be **identical** on both — ayame's Redis enforces it, michi's pangolin presents it |
| `pangolin.example.com` | `ayame/config/config.yml`, `michi/config/config.yml` | your real dashboard domain |
| `<AYAME_SSH_PORT>` | `michi/cert-sync/sync-dashboard-cert.sh` | ayame's SSH port, if not the default `22` |
| `<AYAME_SSH_USER>` | `michi/cert-sync/sync-dashboard-cert.sh` | a non-root user on ayame with sudo — root login itself may be disabled (`PermitRootLogin no`), so the sync key authenticates as this user and a scoped sudoers rule lets it run the one forced-command script as root |
| `<DASHBOARD_DOMAIN>` | `ayame/config/dynamic/bootstrap.yml`, `michi/config/dynamic/bootstrap.yml`, `ayame/config/privateConfig.yml`, `michi/config/privateConfig.yml`, `ayame/cert-sync/*`, `michi/cert-sync/*` | same domain as `dashboard_url`, without the scheme |

## Deploy order

1. On **ayame**: copy the contents of `ayame/` to the host's deployment
   directory (e.g. `/opt/pangolin-cluster`), copy `.env.example` to `.env`
   and fill in `POSTGRES_PASSWORD`, fill in all placeholders above, drop
   `GeoLite2-Country.mmdb` / `GeoLite2-ASN.mmdb` into `config/`, create the
   haproxy runtime socket directory (`mkdir -p haproxy/run && sudo chown
   99:99 haproxy/run` — haproxy crash-loops without it, see "Rolling
   pangolin updates"), then `docker compose up -d`.
2. Set up the WireGuard link between the nodes ("Private network between
   the nodes") before starting anything that binds `10.88.0.1`, and open
   `3004/tcp` to the peer.
3. On **michi**: copy the contents of `michi/` to the host's deployment
   directory (same path convention as ayame), fill in its placeholders
   (same `<CLUSTER_SECRET>` and `POSTGRES_PASSWORD` as ayame), drop the
   GeoLite2 databases into `config/`, then `docker compose up -d`.
4. Point DNS for your dashboard/resource domains at ayame's HAProxy (or at
   both nodes' IPs via round-robin DNS, if you don't want a single point of
   ingress).
5. Put the dashboard cert in `ayame/cert-sync/dashboard-cert/` on ayame
   (`cert.pem` + `key.pem`) — that directory is gitignored, so a fresh
   clone starts empty and **both** nodes will serve Traefik's self-signed
   fallback until it's populated. Then set up the cert sync (below) so
   michi gets a copy.

## Gitignored files that must be carried across a migration

Moving a host's deployment directory (e.g. into a git clone) silently
breaks the cluster if these are left behind, because nothing recreates
them and nothing reports them missing:

- **`config/key`** — gerbil's WireGuard identity. It is generated by
  `--generateAndSaveKeyTo=/var/config/key`, so a fresh clone with no key
  makes gerbil generate a *new* one, which Pangolin registers as a **new
  exit node**. Every resource still bound to the old exit node then has
  nothing behind it: `No exit nodes found for resource.` in the log, no
  router generated on any node, and a permanent `404` for the resource —
  while the site itself looks perfectly connected, because newt happily
  attaches to the new exit node. Confirmed the hard way on michi.
- **`config/certificates/`** — the certs themselves. Pangolin checks its
  *database* to decide whether a cert needs fetching, not the disk, so an
  empty directory plus a valid DB record means it never re-materializes
  the files and Traefik silently falls back to its self-signed cert.
- **`config/account.key`** — the ACME account key.
- **`cert-sync/dashboard-cert/`** (ayame) and `cert-sync/synced-certs/`
  (michi) — the dashboard cert both nodes serve.

Compare before and after with `md5sum` rather than assuming a copy
happened, and check **every** host — an identical key on one node says
nothing about the other.

**If a stray exit node does get created, rename or delete it — marking it
offline is not enough.** A node figures out which exit node it *is* by
name, taking the first row returned, with no `online` filter and no
ordering:

```js
// server/lib/exitNodes/getCurrentExitNodeId.ts
const [exitNode] = await db.select({ exitNodeId: exitNodes.exitNodeId })
    .from(exitNodes).where(eq(exitNodes.name, exitNodeName));
```

Nothing enforces unique names, so a duplicate (say two rows both named
`michi`, one of them an orphan) makes the node's own identity depend on
Postgres row order. Confirmed live: michi believed it was the orphaned
exit node, so its Traefik config query matched no sites, it generated no
routers, and it never claimed a domain — while looking perfectly healthy.
The value is cached per process, so a restart is needed after renaming.

## Private network between the nodes

Postgres and Redis were published on ayame's public IP with a firewall rule
allowing michi. That is one rule away from exposure, it sends database
traffic across the public internet in cleartext, and **Redis takes no
password at all** — it says so on startup: `Redis does not require
authentication and is not protected by network restrictions`. Network
reachability was the entirety of its access control.

A WireGuard link between the nodes fixes the transport. It runs as a
service in each host's `docker-compose.yml`, so deploying it is the same
`git pull && docker compose up -d` as everything else — no separate
systemd unit to keep in sync.

`network_mode: host` is load-bearing: the `wg-cluster` interface has to
exist in the **host** namespace, both so docker can publish Postgres and
Redis on `10.88.0.1` and so michi's containers can route to it. Postgres
and Redis `depends_on` the tunnel's healthcheck (`wg show wg-cluster`), so
they never try to bind an address that doesn't exist yet — which is what
makes this survive a reboot without a docker/systemd ordering hack.

`wireguard/wg_confs/wg-cluster.conf` in each host's folder is that host's
half:

| | ayame | michi |
|---|---|---|
| tunnel address | `10.88.0.1/30` | `10.88.0.2/30` |
| listen port | `51821/udp` | `51821/udp` |

`51821`, not `51820`, because gerbil already publishes `51820/udp` for
Pangolin's own tunnels. `10.88.0.0/30` avoids both gerbil's `100.89.0.0/16`
and the LAN behind urad.

**Setup.** The configs come from the repo; only the private keys are
per-host and stay out of git. On **each** node:

```bash
cd /opt/pangolin-cluster
(umask 077; wg genkey | sudo tee wireguard/privatekey | wg pubkey)
```

The subshell matters. `umask 077 && ...` leaves the umask set for the rest
of that shell session, so every file a later `git pull` writes lands as
`600` — which breaks haproxy specifically, since it is the one container
here that drops privileges and cannot then read its own config
(`Could not open configuration file ... Permission denied`, crash loop,
443 down). Learned the hard way. If it happens anyway:

```bash
cd /opt/pangolin-cluster-repo
sudo find . -path ./.git -prune -o -type f \
  ! -name '*.pem' ! -name 'privatekey' ! -name '.env' -exec chmod 644 {} +
sudo chmod +x ayame/ha-check.sh ayame/haproxy/node-state.sh \
  ayame/cert-sync/*.sh michi/cert-sync/*.sh
```

That prints the **public** key — put each node's public key into the
*other* node's `wg_confs/wg-cluster.conf` as the peer's `PublicKey`, commit,
and pull on both. The configs carry no `PrivateKey` line at all; each
brings its key in at interface setup with
`PostUp = wg set %i private-key /config/privatekey`, which is what lets the
config itself live in git.

Open the tunnel port to the peer only, bring it up, and verify before
pointing anything at it:

```bash
# ayame
sudo ufw allow from <michi public IP> to any port 51821 proto udp
# michi
sudo ufw allow from <ayame public IP> to any port 51821 proto udp

docker compose up -d wireguard
docker compose exec wireguard wg show wg-cluster   # expect a recent handshake
ping -c3 10.88.0.1                                 # from michi
```

Only once that ping works, bring up the rest (`docker compose up -d`).
Postgres and Redis wait on the tunnel's healthcheck, so they will hold
rather than fail if it isn't ready.

Then drop the old public exposure:

```bash
# ayame - no longer needed once michi connects over the tunnel
sudo ufw status numbered | grep -E '5432|6379'
sudo ufw delete <number>          # highest number first
```

Worth an actual reboot test on ayame afterward. The `depends_on` healthcheck
should hold Postgres and Redis until the interface exists, but a reboot is
the only way to know — and this is exactly the kind of thing that otherwise
surfaces months later at the worst possible moment.

**Still not covered:** HAProxy reaches michi over the public internet for
ports 80, 443, and 3000. Port 443 is TLS end to end, but `dashboard_back`
sends port 3000 traffic **in cleartext**. Pointing haproxy's michi server
lines at `10.88.0.2` would fix that and remove the need for michi to
publish those ports publicly at all — worth doing, but it changes the
ingress path, so validate it the same way the health check was validated.

**Redis requires a password.** The tunnel stops it being reachable from
the internet, but anything landing on either host could still talk to it,
so `redis-server --requirepass` is set on ayame and both nodes' pangolin
gets `REDIS_PASSWORD`. Pangolin reads `redis.password` from that env var
(`readConfigFile.ts`, `getEnvOrYaml`), so the secret lives in each host's
gitignored `.env` rather than in `privateConfig.yml`. **The value must be
identical on both hosts** — see `.env.example` in each folder.

**HAProxy reaches michi over the tunnel** (`10.88.0.2`), not its public IP.
`dashboard_back` carries port 3000 in cleartext and used to send it across
the public internet; `websecure_back` was already TLS end to end but has no
reason to leave the tunnel either. michi still publishes those ports
publicly so the monitor's pinned probes (and a future direct-to-michi DNS
path) keep working.

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

## Why `dns.static_records` for the dashboard domain exists

Once the dashboard domain's NS is delegated to Pangolin's own embedded DNS
server (needed for `cert_mode: pangolin`'s DNS-01 challenges), that server
becomes the *only* thing anyone asks for `A` records under that domain — and
it never answers for the bare dashboard domain itself. Its query handler
(`server/private/lib/dns/server.ts`) only ever returns an `A` record for a
name that matches a `resources` row or a `loginPage` row; the dashboard
domain is neither, so it's a permanent `NXDOMAIN` from every public
resolver, even though local resolvers with a manual override (e.g. a
pfSense domain override pointing straight at the server) mask it. This is
the DNS-layer counterpart of the `bootstrap.yml` gap above — same
chicken-and-egg shape, different layer. The `dns.static_records` entry in
`config/privateConfig.yml` (and `michi/config/privateConfig.yml`, kept in
sync) works around it the same way `bootstrap.yml` does for Traefik: a
hand-written record for the one hostname Pangolin's own logic never covers.

Resource hostnames need entries here too, for a different reason — see
"Rolling pangolin updates".

**Static-record names answer AAAA queries with NXDOMAIN, which breaks musl
clients.** `getStaticRecords` matches on domain *and* record type, so an
`AAAA` query for a name that only has a static `A` record matches nothing,
falls through to the resource lookup, finds nothing, and returns NXDOMAIN —
where it should return NODATA (NOERROR with an empty answer), since the name
itself does exist. Resource hostnames get this right (`NODATA (NOERROR) ...
type AAAA` appears in the log for those); static records do not.

glibc ignores a failed AAAA and uses the A record, so curl and browsers
never notice. **musl treats the NXDOMAIN as terminal for the whole lookup**
and fails with `EAI_NONAME`, so anything running on Alpine cannot resolve
the dashboard domain at all. That is why `urad/docker-compose.yml` pins a
Debian-based image instead of Alpine — the monitor caught this on itself,
reporting `gaierror: [Errno -2] Name does not resolve` for the load-balancer
probe while both pinned probes passed.

Earlier in this repo's history the `NXDOMAIN for <dashboard domain>` lines
in pangolin's log were read as this record failing. They were not — those
come from `getLoginPageRecordsByFullDomain`, the *login page* lookup, which
is a separate path.

## The nameserver hostname needs an A record for both nodes

`dns.nameserver_name` (`privateConfig.yml`, e.g. `ns.<yourdomain>`) — the
hostname the dashboard domain's `NS` records delegate to — only had a
single `A` record pointing at ayame. Both `pangolin` containers run their
own embedded DNS server and answer the zone identically (they share the
same Postgres data and `dns.static_records` config), but the *delegation*
only ever pointed resolvers at one of them. Confirmed by directly stopping
ayame's `pangolin` container during an HA test: the entire domain became
unresolvable everywhere (`NXDOMAIN`/`NS_ERROR_UNKNOWN_HOST`), even though
HAProxy, Traefik, and everything else on michi was completely healthy — DNS
resolution for the whole domain was a single point of failure independent
of, and more fundamental than, the HAProxy/ingress layer. Fixed by adding a
second `A` record for the nameserver hostname pointing at michi's IP, so a
resolver that can't reach ayame's nameserver falls back to michi's — this
is a change made directly at your DNS provider (e.g. Cloudflare, for
whatever hosts the parent zone), not anything in this repo.

Postgres, Redis, and HAProxy itself are still single-homed on ayame, so
ayame going down entirely still stops the whole cluster (michi has nowhere
to get data from, and there's no other ingress point) — this fix only
closes the DNS-specific gap, not that broader one.

## Why `websecure_back`'s health check is an HTTPS request, not a TCP check

A plain TCP check only proves Traefik's port is open — it says nothing
about whether the actual backend Traefik proxies to is reachable.
Confirmed live during an HA test: stopping just the `pangolin` container
(leaving `gerbil`/`traefik` running) left ayame's `websecure_back` server
looking perfectly healthy to a TCP check, since Traefik itself was still
listening fine on `8443` — but every real request routed there got a `502`
from Traefik, since `bootstrap.yml`'s routers proxy to `http://pangolin:3000`/
`3002`, and pangolin was down. HAProxy kept sending roughly half its
round-robined traffic into that dead end the whole time.

The fix is `option httpchk` with an `http-check send hdr Host <dashboard
domain>` and `check-ssl verify none sni str(<dashboard domain>)` on the
server lines, so the check makes the same request real dashboard traffic
makes and only reports up when pangolin is actually answering.

A first attempt at this was **reverted immediately**: both servers failed
with `SSL handshake failure` and HAProxy logged `backend 'websecure_back'
has no server available!`, a full outage on 443. It was missing `sni` —
without it the check's ClientHello carries no server name, unlike real
traffic. The corrected version was validated *before* adoption on a
traffic-free test backend (referenced by no frontend, visible only on the
stats page) with `pangolin` stopped on ayame: ayame went DOWN, michi stayed
UP, exactly as intended. Use that same pattern for any future change to a
live health check — a broken check takes down every node at once.

At the time this was blamed on a suspected Traefik TLS/ALPN bug, because
`curl` consistently failed against Traefik while `openssl s_client`
consistently succeeded. **That theory was wrong.** curl was failing because
ayame was serving Traefik's *self-signed fallback* cert and curl rejects it
(`TLS alert, unknown CA`, connection closed mid-handshake, no HTTP status —
which is why it looked like a transport-layer bug); `openssl s_client`
"succeeded" only because it doesn't validate the chain by default. See the
next section — that self-signed cert was a real, separate outage.

Note that this check covers ingress only. Stopping `pangolin` also kills
that node's authoritative DNS server (it owns `53/udp`), and no
load-balancer health check can compensate for a dead nameserver — see the
`ns.simplycrafted.net` section above.

## Rolling pangolin updates (HA for resources)

Pangolin's clustering gives a *site* one exit node at a time:
`sites.exitNodeId` is a single column, and
`handleNewtExitNodesRequestMessage.ts` hands newt a weighted list to pick
**one** from. So a resource is served only by the node its site is attached
to, and stopping that node's `pangolin` takes the resource down — the
`badger` middleware calls `pangolin:3001` on every request, so a running
Traefik alone isn't enough.

The way to get a resource served by both nodes is to give it a target on a
site attached to each. Each node builds its Traefik config from
`sites INNER JOIN targets INNER JOIN resources WHERE sites.exitNodeId =
<this node>` (`getTraefikConfig.ts`), so a dual-homed resource gets a
router on both, each proxying through its own tunnel.

**Setup:**

1. Run **two newt clients** on the site host, registering as two sites.
2. Pin one site per node by capping each exit node at a single connection.
   `calculateExitNodeWeight` returns `null` at capacity, which filters that
   node out of the list newt is offered:
   ```sql
   UPDATE "exitNodes" SET "maxConnections" = 1 WHERE online = true;
   ```
   No API or UI writes this column, so it is set directly in Postgres. It
   survives restarts: re-registration only updates `reachableAt`/`online`.
   Restart the second newt after setting it, so it re-selects onto the
   other node.
3. Give **every resource a second target** — same internal IP and port, via
   the second site.
4. Add **two** `dns.static_records` entries per resource hostname — one per
   node's public IP — in **both** nodes' configs, so clients land on either
   load balancer. `getStaticRecords` returns every entry matching the name
   and type, so two entries produce two `A` records.

   Pangolin's own DNS would otherwise answer resources itself, returning an
   `A` record for each online exit node (`server.ts:721-735`), falling back
   to one deterministic node only when none are online. That is the
   upstream design and it works — but it fails over only on a refused
   connection, cannot express "draining", and keeps handing out a node that
   is up but broken for the full TTL. Static records pointing at the load
   balancers trade that for health-checked, drainable failover in about two
   seconds. (Latency-based steering is *not* implemented in this version —
   it appears twice in `server.ts` as a TODO.)
5. Leave `websecure_front` balanced across both nodes (its default).

**Never restart or update both nodes at once.** Everything here assumes one
node is always healthy: the health checks run *through* Traefik to pangolin,
so restarting both pangolins together fails every backend's check at the
same moment and leaves nothing to serve from. Observed live as a burst of
`000`s with all six backends DOWN on both load balancers. Do one node,
confirm it is green, then the other.

**Then updating a node is:** drain it first, so no request is ever routed
to a node that is about to stop. Relying on the health check alone costs a
couple of `502`s while it notices — measured, not theoretical.

The socket lives on a bind mount at `ayame/haproxy/run/admin.sock`. That
directory is gitignored, so **it has to be created and chowned to the
image's `haproxy` user before starting haproxy** — the container drops
privileges and cannot bind a socket in a root-owned directory. It fails
closed: haproxy refuses to start at all and crash-loops, taking port 443
down with it.

```bash
mkdir -p haproxy/run
sudo chown 99:99 haproxy/run     # confirm with: docker run --rm haproxy:3.4-alpine id haproxy
```

Then, to update a node, use `ayame/haproxy/node-state.sh` — it drains all
three backends at once and refuses to run if the socket path isn't
actually a socket:

```bash
# on ayame
sudo ./haproxy/node-state.sh michi maint

# on the node being updated
docker compose pull && docker compose up -d

# back on ayame, once it is healthy
sudo ./haproxy/node-state.sh michi ready
```

The equivalent by hand, if the script isn't available:

```bash
echo "set server websecure_back/michi state maint" | \
  sudo socat stdio UNIX-CONNECT:/opt/pangolin-cluster/haproxy/run/admin.sock
```

**The `UNIX-CONNECT:` prefix is mandatory.** A bare path makes socat use
`GOPEN`, which *creates a regular file* at that path instead of connecting
to the socket. Doing that replaces `admin.sock` with a text file, and
haproxy then cannot rebind it (`error when trying to preserve previous UNIX
socket`) — another crash loop, another 443 outage. Learned the hard way.
`nc -U <path>` is a safer alternative if the host has it, since it has no
such footgun.

Check the result on the stats page (`:8404/stats`) — the drained server
shows MAINT.
Substitute `websecure_back/ayame` when updating the other node; the same
applies to `web_back` and `dashboard_back` if a node is going down long
enough to matter for plain HTTP or the dashboard port.

The health check remains the backstop for *unplanned* failures, tightened
to `inter 1s fall 2` so an unexpected pangolin death is caught in about two
seconds rather than six.

### Checking HA

`ayame/ha-check.sh` probes every hostname three ways — through the load
balancer and pinned to each node directly — and prints the haproxy backend
states first. The pinned probes are the point: a resource homed on only one
node still passes the load-balanced check about half the time, which is
exactly how one went unnoticed here.

```bash
sudo ./ha-check.sh          # 10 requests per probe
sudo ./ha-check.sh 40       # more, e.g. while draining a node
```

Add each new resource hostname to the `RESOURCES` array at the top. Run it
after adding a resource, after either node is updated, and before trusting
the cluster after any change to sites or exit nodes.

Scenarios worth exercising by hand, all of which have actually broken here:

| Test | Expected |
|---|---|
| `node-state.sh michi maint`, then update michi | no failed requests at all |
| `docker compose stop pangolin` on one node (no drain) | ~2s of errors, then clean |
| `docker compose down` on one node | as above, plus possible DNS blips — that node's nameserver goes too |
| Add a resource with one target | `ha-check.sh` fails the pinned probe for the node it is missing from |
| Both nodes up, steady state | `ha-check.sh` fully green |

### Continuous monitoring (`urad/`)

`ha-check.sh` is a point-in-time check run by hand from ayame. `urad/` is
the continuous version, and it deliberately runs on the **site host rather
than a cluster node**, so it probes the same path a real client takes:
public DNS, HAProxy, whichever node answers, and the target behind it.

It probes every hostname three ways (load balancer, pinned to each node
with SNI intact) on an interval, keeps rolling history across restarts, and
serves a status page plus `api/status` JSON. **Certificates are validated** —
a node serving Traefik's self-signed fallback fails loudly here, rather
than looking like a flaky connection, which is precisely how that outage
presented.

```bash
# on urad
mkdir -p data
docker compose up -d
curl -s localhost:8080/api/status | head
```

Then serve it through the cluster like any other resource, which makes the
monitor itself HA: create a resource pointing at urad's tunnel IP on port
`8080`, give it **two targets** (one per site), add a `dns.static_records`
entry for its hostname on both nodes, and add that hostname to
`RESOURCES` here and in `ha-check.sh`.

Two things to keep in mind:

- **A monitor served through the cluster cannot report a total cluster
  outage** — the page is unreachable exactly when it matters most. It keeps
  recording locally, so the gap is visible afterward, but also reach it
  directly on urad (`http://urad:8080`, or a pfSense override) for the case
  where the cluster is down.
- **Don't set `INTERVAL` too low.** Each cycle opens one connection per
  hostname per node; a firewall with a rate limit on 443 will start
  dropping them and the monitor will report failures it caused itself.
  30s is comfortable.

**Caveats:**

- **Every resource must be dual-homed.** A single-target resource is served
  by one node, and the balanced frontend will send half its traffic to a
  node that answers `404`. Adding a resource means adding two targets and
  a static record, every time.
- **Changing a target's address does not move its health check.** Confirmed
  live: after repointing a resource from one host to another, newt logged
  `Started tcp proxy to <new address>` (correct) alongside `Starting health
  check monitoring for target N (<old address>)` and then
  `health check failed with status code 404` / `initial status: unhealthy`.
  An unhealthy target is dropped from the server list
  (`getTraefikConfig.ts:590-598`), so Pangolin emits the router with
  `servers: []` and Traefik answers **503** — with a data path that looks
  entirely correct end to end. Update or disable the health check on each
  target when its address changes, and restart newt so it re-reads the
  config. A `503` where `curl` to the target works from inside newt's
  namespace is almost always this.
- **`maxConnections` counts clients too**, not just sites
  (`calculateExitNodeWeight` sums `sites` and `clients`). A cap of 1 will
  refuse Pangolin client VPN connections. If you use those, pin sites with
  remote exit nodes and `remoteExitNodePreferenceLabels` instead.
- **The cap intentionally prevents newt failover** — a site cannot relocate
  to a node that is already at capacity. That is the point here
  (availability comes from the other site already serving, not from
  relocation), but it means a node that stays down leaves its site down.
- **Postgres, Redis, and HAProxy are still ayame-only.** This makes the
  pangolin/gerbil/traefik layer rolling-updatable; it does not make ayame
  expendable.

## Why the dashboard cert is synced from ayame to michi

Pangolin's certificate pipeline (`TraefikConfigManager.ts`) is scoped **per
exit node**: a node only fetches/writes a cert for a domain that a resource
or login page assigned to *that node's own exit node ID* actually needs —
confirmed by reading both the OSS `TraefikConfigManager.ts` and the EE
`getTraefikConfig.ts`'s login-page router generation, which both filter
strictly by `exitNodeId`. Certificate files live on local disk only
(`config/certificates/`), never in the shared Postgres/Redis — there is no
built-in mechanism that replicates a cert across nodes for a domain both
need to serve behind a round-robin load balancer. Pangolin's clustering is
built for node failover, not concurrent same-domain multi-node serving,
which is what our own HAProxy layer asks of it.

On ayame, the dashboard domain's wildcard cert originally existed only
because the `test` resource's site happened to be pinned to ayame's exit
node, which pulled in a wildcard cert whose SANs also cover the bare
dashboard domain. Michi has no resource or login page pinned to its exit
node, so its own cert-fetch cycle never runs for any domain, dashboard
included — it would otherwise only ever serve Traefik's self-signed
fallback cert.

**That arrangement is fragile, and it has already broken once.** When
nothing active claims the dashboard domain on ayame's exit node, ayame is
in exactly michi's position: the janitor reaps the cert and Traefik falls
back to self-signed. That happened live — pangolin logged `No exit nodes
found for resource.` / `NXDOMAIN for auth.simplycrafted.net`, then
`Certificate <domain> is no longer in use. Will delete after 3 more
cycles.` and `Cleaning up unused certificate directory`, on a loop every
few minutes. Restoring the files by hand did nothing; they were deleted
again within ~20 seconds each time. So **ayame serves the dashboard cert
from a janitor-proof path too** (`ayame/cert-sync/dashboard-cert/`,
bind-mounted as `/var/dashboard-cert`, referenced from
`ayame/config/dynamic/bootstrap.yml`) — the same pattern as michi, for the
same reason. ayame's copy is also what michi syncs *from*, so the sync no
longer depends on a directory Pangolin deletes.

**Both `tls.certificates` blocks are now commented out**, because pinning a
site to each node fixed the underlying problem: each node claims the domain
and Pangolin's own pipeline keeps the cert current in `cert_config.yml`.
Leaving our static definition in place alongside it was actively harmful —
Traefik kept the first definition it saw (ours) and logged `TLS certificate
{...} already configured, skipping origin=cert_config.yml` on every reload,
printing the full certificate **and private key** into the container log
each time. It also meant Traefik served the static copy while ignoring the
managed one, so a renewal would never have reached clients.

The blocks are commented rather than deleted and the bind mounts are still
in place, so if a node ever loses its claim again (its site offline long
enough for the janitor to run), restoring the cert is: repopulate that
node's janitor-proof directory and uncomment the block.

The fix: a small SSH-based sync job on michi (systemd timer, every 6 hours)
pulls `cert.pem`/`key.pem` from ayame's `cert-sync/dashboard-cert/` into
`cert-sync/synced-certs/` on michi, and
`michi/config/dynamic/bootstrap.yml` has a hand-written `tls.certificates`
entry pointing at them — the same "bypass Pangolin's own per-node logic"
pattern as the router and DNS fixes above. Traefik reloads a referenced
cert file automatically whenever its content changes, so nothing needs to
touch `bootstrap.yml` again once this is set up; only the synced files
change on renewal. The sync uses a restricted forced-command SSH key (michi
can only read those two specific files on ayame, nothing else) rather than
a general-purpose key.

How this presented, for future reference: roughly half of all HTTPS
requests failed with no HTTP status at all (`curl` reporting `000`), which
looked like flaky networking or a load-balancer fault. It was neither —
every request round-robined onto ayame hit the self-signed cert and was
rejected client-side, while every request onto michi succeeded. Stopping
michi took it to 100% failure and finally made it obvious.

**This sync is now redundant** — both nodes claim the domain and maintain
their own cert, and the `tls.certificates` blocks that consumed the synced
copy are commented out. Leave the timer running until it has survived one
real renewal, then disable it (`systemctl disable --now
pangolin-cert-sync.timer` on michi). Keep the scripts and mounts: if a node
ever loses its claim again, re-enabling both is the fastest recovery.

**The cert files must not land in `config/certificates/` on either node.**
That directory is also Pangolin's own certificate store, and its janitor
(`cleanupUnusedCertificates` in `TraefikConfigManager.ts`) force-deletes
any domain directory there that isn't one of *this node's own* currently
active domains, with only a ~15 second grace period — confirmed the hard
way on both hosts: on michi the first working sync got deleted within about
15 minutes, leaving Traefik logging `failed to find any PEM data in
certificate input` for a file that had simply ceased to exist; on ayame,
hand-restored files were gone in under 20 seconds. `cert-sync/synced-certs/`
on michi and `cert-sync/dashboard-cert/` on ayame are bind-mounted into the
traefik container as a *separate* path (`/var/dashboard-cert`, read-only)
that Pangolin's janitor never scans, and each node's `bootstrap.yml`
`tls.certificates` entry points there instead of into `/var/certificates`.

### Setup

Each host only ever needs the scripts already inside its own deployed
folder (`ayame/cert-sync/` on ayame, `michi/cert-sync/` on michi) — nothing
needs to be copied across hosts.

**1. On michi: generate a dedicated keypair** (no passphrase — this runs
unattended from a systemd timer):

```bash
ssh-keygen -t ed25519 -f ./cert-sync/cert-sync-key -N "" -C "michi-cert-sync"
cat ./cert-sync/cert-sync-key.pub
```

Copy the printed public key.

**2. On ayame: authorize that key against a non-root user, restricted to the
sync script only.** If root login is disabled (`PermitRootLogin no` in
`sshd_config` — check with `grep PermitRootLogin /etc/ssh/sshd_config`), the
key has to authenticate as a regular sudo-capable user instead; a scoped
sudoers rule then lets *that one script* run as root without a password,
which is what it needs to read `key.pem` (mode `600`, root-owned):

```bash
chmod +x ./cert-sync/cert-sync-allowed.sh
mkdir -p ~/.ssh
echo 'command="sudo '"$(pwd)"'/cert-sync/cert-sync-allowed.sh",no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty PASTE_MICHI_PUBLIC_KEY_HERE' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

sudo tee /etc/sudoers.d/cert-sync > /dev/null <<EOF
$(whoami) ALL=(root) NOPASSWD: $(pwd)/cert-sync/cert-sync-allowed.sh
Defaults!$(pwd)/cert-sync/cert-sync-allowed.sh env_keep += "SSH_ORIGINAL_COMMAND"
EOF
sudo chmod 440 /etc/sudoers.d/cert-sync
sudo visudo -cf /etc/sudoers.d/cert-sync   # validates syntax before it's live
```

Replace `PASTE_MICHI_PUBLIC_KEY_HERE` with the full `ssh-ed25519 AAAA...
michi-cert-sync` line from step 1. This key can only ever run
`cert-sync-allowed.sh` (as root, via that one narrowly-scoped sudoers rule),
which itself only allows reading
`cert-sync/dashboard-cert/{cert.pem,key.pem}` — nothing else,
no shell, and root SSH login stays fully disabled throughout. Set
`<AYAME_SSH_USER>` in `michi/cert-sync/sync-dashboard-cert.sh` to whichever
user you ran this as.

The `env_keep` line matters: `sudo` strips almost all environment variables
by default (`env_reset`), including `$SSH_ORIGINAL_COMMAND` — which is
exactly what `cert-sync-allowed.sh` reads to decide whether to serve
`get-cert` or `get-key`. Without it, the script always falls through to
"command not permitted" no matter what the client asked for.

If root login is *not* disabled on your ayame, you can skip the sudoers
step and use `/root/.ssh/authorized_keys` with `command="..."` (no `sudo`
prefix) instead, with `<AYAME_SSH_USER>` set to `root`.

**3. On michi: do a first sync manually, then enable the timer:**

```bash
chmod +x ./cert-sync/sync-dashboard-cert.sh
./cert-sync/sync-dashboard-cert.sh   # first run - accept ayame's host key when prompted

cp ./cert-sync/pangolin-cert-sync.service /etc/systemd/system/
cp ./cert-sync/pangolin-cert-sync.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pangolin-cert-sync.timer
```

**4. Verify:**

```bash
systemctl list-timers pangolin-cert-sync.timer
openssl s_client -connect <MICHI_PUBLIC_IP>:443 -servername <DASHBOARD_DOMAIN> </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject
```

Should show Let's Encrypt as the issuer instead of `TRAEFIK DEFAULT CERT`.
Check the *issuer*, not just that a handshake completed — `openssl
s_client` does not validate the chain by default, so it will happily print
a self-signed cert and exit `0`. To check the way a real client does, use
`curl -sv https://<DASHBOARD_DOMAIN>/ -o /dev/null` and confirm there's no
`unknown CA` alert.

## Source

Adapted from Pangolin's official [HA reference
config](https://github.com/fosrl/pangolin/tree/main/config/ha-reference) and
[clustering docs](https://docs.pangolin.net/self-host/clustering/deploy-a-cluster).
