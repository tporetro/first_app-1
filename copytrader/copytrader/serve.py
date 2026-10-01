"""Always-on mode: run the engine forever and serve the dashboard over HTTP.

* The engine runs in a background thread and is restarted (with backoff) if it crashes.
* The dashboard is re-rendered from the ledger every ``refresh_s`` seconds.
* ``GET /?key=<DASHBOARD_KEY>`` returns the dashboard; ``GET /health`` is open for the host's
  health checks. Without DASHBOARD_KEY set, only /health is served.
"""
from __future__ import annotations

import hmac
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import ledger as ledger_mod
from .dashboard import render

log = logging.getLogger(__name__)


class Supervisor:
    def __init__(self, make_engine, ledger_path: str, out_html: str, refresh_s: float = 60.0):
        self.make_engine = make_engine
        self.ledger_path, self.out_html, self.refresh_s = ledger_path, out_html, refresh_s
        self.started = time.time()
        self.restarts = 0
        self.last_error = None
        self.engine = None

    def _engine_loop(self) -> None:
        backoff = 5
        while True:
            try:
                self.engine = self.make_engine()
                self.engine.run()  # returns only on stop/duration
                backoff = 5
            except Exception as e:  # noqa: BLE001
                self.last_error = f"{time.strftime('%H:%M:%S')} {e!r}"
                log.exception("Engine crashed; restarting in %ss", backoff)
            self.restarts += 1
            time.sleep(backoff)
            backoff = min(backoff * 2, 300)

    def _render_loop(self) -> None:
        while True:
            try:
                render([(self.ledger_path, "Live")], self.out_html)
            except Exception as e:  # noqa: BLE001
                log.warning("Dashboard render failed: %s", e)
            time.sleep(self.refresh_s)

    def start(self) -> None:
        threading.Thread(target=self._engine_loop, name="engine", daemon=True).start()
        threading.Thread(target=self._render_loop, name="dashboard", daemon=True).start()

    def health(self) -> dict:
        stats = getattr(self.engine, "stats", {}) if self.engine else {}
        ws = bool(self.engine and self.engine.stream.ws_connected)
        return {"ok": True, "uptime_s": int(time.time() - self.started), "restarts": self.restarts,
                "websocket": ws, "stats": stats, "last_error": self.last_error,
                "ledger_records": ledger_mod.verify(self.ledger_path).records}


def make_handler(sup: Supervisor, key: str | None):
    import json

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # keep keys out of logs
            log.debug("http %s", self.path.split("?")[0])

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/health":
                return self._send(200, json.dumps(sup.health()).encode(), "application/json")
            given = parse_qs(url.query).get("key", [""])[0]
            if not key or not hmac.compare_digest(given, key):
                return self._send(403, b"Forbidden: add ?key=<DASHBOARD_KEY> to the URL", "text/plain")
            if url.path in ("/", "/dashboard"):
                try:
                    with open(sup.out_html, "rb") as fh:
                        body = fh.read()
                except FileNotFoundError:
                    body = b"<p>Starting up. Refresh in a minute.</p>"
                page = (b'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" '
                        b'content="width=device-width,initial-scale=1,viewport-fit=cover">'
                        b'<meta http-equiv="refresh" content="120"></head><body>' + body + b"</body></html>")
                return self._send(200, page, "text/html; charset=utf-8")
            if url.path == "/ledger.jsonl":
                with open(sup.ledger_path, "rb") as fh:
                    return self._send(200, fh.read(), "application/x-ndjson")
            return self._send(404, b"Not found", "text/plain")

    return Handler


def serve(make_engine, ledger_path: str, out_html: str, port: int) -> None:
    key = os.environ.get("DASHBOARD_KEY")
    if not key:
        log.warning("DASHBOARD_KEY not set: dashboard disabled, only /health is served")
    sup = Supervisor(make_engine, ledger_path, out_html)
    sup.start()
    log.info("Serving on :%d (dashboard at /?key=...)", port)
    ThreadingHTTPServer(("0.0.0.0", port), make_handler(sup, key)).serve_forever()
