#!/usr/bin/env python3
"""Continuous HA probe for the Pangolin cluster, served as a status page.

Runs on urad - outside the cluster - so it exercises the same path a real
client takes: public DNS, HAProxy, one of the two nodes, its Traefik, and
whatever sits behind it.

Every hostname is probed three ways: through the load balancer, and pinned
to each node's IP with SNI intact. The pinned probes are what distinguish
"the cluster is serving" from "both nodes are healthy" - a resource homed
on one node still passes the load-balanced probe about half the time.

Certificates are validated. A node serving Traefik's self-signed fallback
fails here rather than looking like a flaky connection, which is exactly
how that failure presented when it happened.
"""

import json
import os
import socket
import ssl
import threading
import time
import urllib.request
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# All infrastructure values come from the environment (see
# docker-compose.yml), so this file carries no hostnames or IPs and stays
# identical between the template and live-config repos.
DASHBOARD = os.environ.get("DASHBOARD", "")
RESOURCES = [r for r in os.environ.get("RESOURCES", "").split(",") if r]
NODES = dict(
    pair.split("=", 1) for pair in os.environ.get("NODES", "").split(",") if "=" in pair
)
INTERVAL = int(os.environ.get("INTERVAL", "30"))
TIMEOUT = float(os.environ.get("TIMEOUT", "5"))
HISTORY = int(os.environ.get("HISTORY", "240"))
HAPROXY_STATS = os.environ.get("HAPROXY_STATS", "")
STATE_PATH = os.environ.get("STATE_PATH", "/data/state.json")
PORT = int(os.environ.get("PORT", "8080"))

lock = threading.Lock()
checks: dict[str, dict] = {}
backends: list[dict] = []
last_run = None


def probe(host: str, ip: str | None) -> tuple[int, float, str]:
    """One HTTPS GET. Returns (status, milliseconds, error)."""
    target = ip or host
    started = time.monotonic()
    try:
        with socket.create_connection((target, 443), timeout=TIMEOUT) as raw:
            ctx = ssl.create_default_context()
            with ctx.wrap_socket(raw, server_hostname=host) as tls:
                tls.sendall(
                    f"GET / HTTP/1.1\r\nHost: {host}\r\n"
                    f"User-Agent: pangolin-monitor\r\nConnection: close\r\n\r\n".encode()
                )
                buf = b""
                while b"\r\n" not in buf:
                    chunk = tls.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
        elapsed = (time.monotonic() - started) * 1000
        line = buf.split(b"\r\n", 1)[0].decode("latin1")
        return int(line.split()[1]), elapsed, ""
    except Exception as exc:  # noqa: BLE001 - any failure is just a failed probe
        return 0, (time.monotonic() - started) * 1000, f"{type(exc).__name__}: {exc}"[:160]


def fetch_backends() -> list[dict]:
    if not HAPROXY_STATS:
        return []
    try:
        with urllib.request.urlopen(HAPROXY_STATS, timeout=TIMEOUT) as resp:
            rows = resp.read().decode("utf-8", "replace").splitlines()
    except Exception:  # noqa: BLE001
        return []
    out = []
    for row in rows:
        cols = row.split(",")
        if len(cols) > 17 and cols[0].endswith("_back") and cols[1] not in ("BACKEND", "FRONTEND", ""):
            out.append({"backend": cols[0], "server": cols[1], "status": cols[17]})
    return out


def targets() -> list[tuple[str, str, str | None]]:
    out = []
    for host in [DASHBOARD, *RESOURCES]:
        out.append((f"{host} via load balancer", host, None))
        for name, ip in NODES.items():
            out.append((f"{host} pinned to {name}", host, ip))
    return out


def record(key: str, code: int, ms: float, err: str) -> None:
    entry = checks.setdefault(
        key, {"history": deque(maxlen=HISTORY), "since": None, "last_error": ""}
    )
    ok = code == 200
    previous = entry["history"][-1]["ok"] if entry["history"] else None
    if previous is None or previous != ok:
        entry["since"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    entry["history"].append({"ok": ok, "code": code, "ms": round(ms), "t": time.time()})
    entry["last_error"] = err


def save_state() -> None:
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(STATE_PATH, "w") as fh:
            json.dump(
                {k: {"history": list(v["history"]), "since": v["since"],
                     "last_error": v["last_error"]} for k, v in checks.items()},
                fh,
            )
    except OSError:
        pass


def load_state() -> None:
    try:
        with open(STATE_PATH) as fh:
            saved = json.load(fh)
    except (OSError, ValueError):
        return
    for key, value in saved.items():
        checks[key] = {
            "history": deque(value.get("history", []), maxlen=HISTORY),
            "since": value.get("since"),
            "last_error": value.get("last_error", ""),
        }


def loop() -> None:
    global last_run, backends
    while True:
        results = [(label, *probe(host, ip)) for label, host, ip in targets()]
        fetched = fetch_backends()
        with lock:
            for label, code, ms, err in results:
                record(label, code, ms, err)
            backends = fetched
            last_run = datetime.now(timezone.utc).isoformat(timespec="seconds")
            save_state()
        time.sleep(INTERVAL)


def snapshot() -> dict:
    with lock:
        out = {"generated": last_run, "interval": INTERVAL, "backends": list(backends), "checks": []}
        for label, entry in checks.items():
            hist = list(entry["history"])
            recent = hist[-1] if hist else None
            good = sum(1 for h in hist if h["ok"])
            out["checks"].append(
                {
                    "name": label,
                    "ok": bool(recent and recent["ok"]),
                    "code": recent["code"] if recent else None,
                    "ms": recent["ms"] if recent else None,
                    "uptime": round(100 * good / len(hist), 1) if hist else None,
                    "samples": len(hist),
                    "since": entry["since"],
                    "last_error": entry["last_error"],
                    "strip": [h["ok"] for h in hist[-60:]],
                }
            )
    return out


PAGE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cluster Status</title>
<style>
:root{--bg:#f7f7f8;--fg:#1a1a1a;--muted:#6b6b70;--card:#fff;--line:#e3e3e6;
--ok:#1a7f4b;--bad:#c0392b;--okbg:#e6f4ec;--badbg:#fbeae8}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
--bg:#111113;--fg:#ececef;--muted:#9a9aa2;--card:#1a1a1d;--line:#2c2c31;
--ok:#4ade80;--bad:#f87171;--okbg:#14301f;--badbg:#341a1a}}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);
font:15px/1.5 ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:860px;margin:0 auto}
h1{font-size:20px;margin:0 0 4px}
.sub{color:var(--muted);font-size:13px;margin-bottom:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;
padding:14px 16px;margin-bottom:10px}
.row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.name{font-weight:600;flex:1;min-width:220px}
.badge{font-size:12px;font-weight:600;padding:2px 8px;border-radius:999px}
.up{color:var(--ok);background:var(--okbg)}
.down{color:var(--bad);background:var(--badbg)}
.meta{color:var(--muted);font-size:12.5px;margin-top:6px}
.strip{display:flex;gap:2px;margin-top:10px}
.strip i{flex:1;height:18px;border-radius:2px;background:var(--ok);opacity:.85}
.strip i.b{background:var(--bad)}
.err{color:var(--bad);font-size:12.5px;margin-top:6px;word-break:break-word}
.bk{display:inline-block;font-size:12px;margin:2px 6px 2px 0;padding:2px 8px;
border-radius:6px;border:1px solid var(--line)}
</style></head><body><main>
<h1>Pangolin cluster status</h1>
<div class="sub" id="sub">loading…</div>
<div id="backends"></div>
<div id="list"></div>
</main><script>
async function tick(){
  const r = await fetch('api/status'); const d = await r.json();
  document.getElementById('sub').textContent =
    'last probe ' + (d.generated||'—') + ' · every ' + d.interval + 's';
  document.getElementById('backends').innerHTML = d.backends.length
    ? '<div class="card"><div class="name">haproxy backends</div><div style="margin-top:8px">' +
      d.backends.map(b=>'<span class="bk">'+b.backend+'/'+b.server+': '+b.status+'</span>').join('') +
      '</div></div>' : '';
  document.getElementById('list').innerHTML = d.checks.map(c=>`
    <div class="card">
      <div class="row">
        <span class="name">${c.name}</span>
        <span class="badge ${c.ok?'up':'down'}">${c.ok?'UP':'DOWN'}</span>
      </div>
      <div class="meta">${c.code??'—'} · ${c.ms??'—'} ms · ${c.uptime??'—'}% of ${c.samples} · since ${c.since??'—'}</div>
      <div class="strip">${c.strip.map(o=>'<i class="'+(o?'':'b')+'"></i>').join('')}</div>
      ${c.last_error?'<div class="err">'+c.last_error+'</div>':''}
    </div>`).join('');
}
tick(); setInterval(tick, 10000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/").endswith("api/status"):
            body = json.dumps(snapshot()).encode()
            ctype = "application/json"
        elif self.path.rstrip("/").endswith("healthz"):
            body, ctype = b"ok", "text/plain"
        else:
            body, ctype = PAGE.encode(), "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if not DASHBOARD or not NODES:
        raise SystemExit("set DASHBOARD and NODES (see docker-compose.yml)")
    load_state()
    threading.Thread(target=loop, daemon=True).start()
    print(f"monitor listening on :{PORT}, probing every {INTERVAL}s", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
