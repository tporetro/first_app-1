"""Kalshi Trade API v2 client: request signing, market discovery, balance, orders.

Auth: each request carries KALSHI-ACCESS-KEY / -TIMESTAMP / -SIGNATURE where the
signature is over ``timestamp + METHOD + path`` (path without query string),
using Ed25519 or RSA-PSS(SHA-256) depending on the key type.

Orders use the V2 single-book shape (``POST /portfolio/events/orders``):
``side`` is ``bid`` (long YES) or ``ask`` (long NO) and ``price`` is always the
YES-leg price in dollars. Buying NO at $0.30 is therefore ``side=ask, price=0.70``.
"""
from __future__ import annotations

import base64
import logging
import os
import time
from typing import Optional
from urllib.parse import urlparse

import requests

from .config import KalshiConfig
from .models import KalshiCandidate

log = logging.getLogger(__name__)


class KalshiAuthError(RuntimeError):
    pass


class Signer:
    def __init__(self, key_id: str, pem_bytes: bytes):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ed25519, rsa

        self.key_id = key_id
        self._key = serialization.load_pem_private_key(pem_bytes, password=None)
        if isinstance(self._key, ed25519.Ed25519PrivateKey):
            self.kind = "ed25519"
        elif isinstance(self._key, rsa.RSAPrivateKey):
            self.kind = "rsa"
        else:
            raise KalshiAuthError("Unsupported Kalshi key type (need Ed25519 or RSA)")

    def sign(self, text: str) -> str:
        msg = text.encode()
        if self.kind == "ed25519":
            sig = self._key.sign(msg)
        else:
            from cryptography.hazmat.primitives import hashes
            from cryptography.hazmat.primitives.asymmetric import padding

            sig = self._key.sign(
                msg,
                padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=padding.PSS.DIGEST_LENGTH),
                hashes.SHA256(),
            )
        return base64.b64encode(sig).decode()

    def headers(self, method: str, full_url: str) -> dict:
        ts = str(int(time.time() * 1000))
        path = urlparse(full_url).path
        return {
            "KALSHI-ACCESS-KEY": self.key_id,
            "KALSHI-ACCESS-TIMESTAMP": ts,
            "KALSHI-ACCESS-SIGNATURE": self.sign(ts + method.upper() + path),
        }


def _f(v) -> Optional[float]:
    try:
        return float(v) if v is not None and v != "" else None
    except (TypeError, ValueError):
        return None


class KalshiClient:
    def __init__(self, cfg: KalshiConfig, session: Optional[requests.Session] = None):
        self.cfg = cfg
        self.base = cfg.base_url
        self.s = session or requests.Session()
        self.signer: Optional[Signer] = None
        key_id = os.environ.get(cfg.key_id_env)
        key_path = os.environ.get(cfg.private_key_path_env)
        if key_id and key_path:
            with open(os.path.expanduser(key_path), "rb") as fh:
                self.signer = Signer(key_id, fh.read())
            log.info("Kalshi credentials loaded (%s key, %s)", self.signer.kind, cfg.env)

    @property
    def authenticated(self) -> bool:
        return self.signer is not None

    def _req(self, method: str, path: str, *, auth: bool = False, params=None, json=None):
        url = f"{self.base}{path}"
        headers = {"Content-Type": "application/json"} if json is not None else {}
        for attempt in range(3):
            if auth:
                if not self.signer:
                    raise KalshiAuthError(
                        f"Set {self.cfg.key_id_env} and {self.cfg.private_key_path_env} for authenticated calls"
                    )
                headers.update(self.signer.headers(method, url))  # fresh timestamp per attempt
            r = self.s.request(method, url, params=params, json=json, headers=headers,
                               timeout=self.cfg.timeout_s)
            # Never blind-retry order placement on 5xx: client_order_id makes it idempotent,
            # but we'd rather surface the error than risk anything.
            retryable = r.status_code == 429 or (r.status_code >= 500 and method == "GET")
            if retryable and attempt < 2:
                time.sleep(1.5 * (attempt + 1))
                continue
            if r.status_code >= 400:
                raise requests.HTTPError(f"Kalshi {method} {path} -> {r.status_code}: {r.text[:500]}",
                                         response=r)
            return r.json() if r.content else {}

    # -- public market data ---------------------------------------------
    def list_candidates(self, categories: list[str], max_pages: int = 60) -> list[KalshiCandidate]:
        cats = {c.lower() for c in categories}
        out, cursor = [], None
        for _ in range(max_pages):
            params = {"status": "open", "with_nested_markets": "true", "limit": 200}
            if cursor:
                params["cursor"] = cursor
            data = self._req("GET", "/events", params=params)
            for ev in data.get("events", []):
                if cats and str(ev.get("category", "")).lower() not in cats:
                    continue
                for m in ev.get("markets") or []:
                    if m.get("status") not in ("active", "open"):
                        continue
                    out.append(
                        KalshiCandidate(
                            ticker=m["ticker"],
                            event_ticker=ev.get("event_ticker", ""),
                            series_ticker=ev.get("series_ticker", ""),
                            category=ev.get("category", ""),
                            title=m.get("title") or ev.get("title", ""),
                            event_title=ev.get("title", ""),
                            yes_sub_title=m.get("yes_sub_title") or "",
                            no_sub_title=m.get("no_sub_title") or "",
                            close_time=m.get("close_time") or "",
                            rules=(m.get("rules_primary") or "")[:600],
                        )
                    )
            cursor = data.get("cursor")
            if not cursor:
                break
        return out

    def quote(self, ticker: str) -> dict:
        """Best bid/ask for both outcomes in dollars, plus status."""
        m = self._req("GET", f"/markets/{ticker}").get("market", {})
        return {
            "ticker": ticker,
            "status": m.get("status"),
            "yes_ask": _f(m.get("yes_ask_dollars")),
            "yes_bid": _f(m.get("yes_bid_dollars")),
            "no_ask": _f(m.get("no_ask_dollars")),
            "no_bid": _f(m.get("no_bid_dollars")),
            "last": _f(m.get("last_price_dollars")),
            "close_time": m.get("close_time"),
            "title": m.get("title"),
        }

    # -- portfolio ------------------------------------------------------
    def balance_usd(self) -> float:
        d = self._req("GET", "/portfolio/balance", auth=True)
        if d.get("balance_dollars") is not None:
            return float(d["balance_dollars"])
        return float(d.get("balance", 0)) / 100.0

    def create_order(self, payload: dict) -> dict:
        return self._req("POST", "/portfolio/events/orders", auth=True, json=payload)
