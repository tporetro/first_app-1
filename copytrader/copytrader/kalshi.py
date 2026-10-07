"""Kalshi REST client (RSA-PSS signed) with a hard dry-run barrier."""
import base64, time, uuid
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding


def _cents(m: dict, key: str):
    """Kalshi returns cents ints (yes_ask) and/or dollar strings (yes_ask_dollars)."""
    if m.get(key) is not None:
        return int(m[key])
    d = m.get(f"{key}_dollars")
    return int(round(float(d) * 100)) if d not in (None, "") else None


class KalshiClient:
    def __init__(self, base_url, key_id="", private_key_path="", session=None):
        self.base = base_url.rstrip("/")
        self.key_id = key_id
        self.s = session or requests.Session()
        self.key = None
        if key_id and private_key_path:
            with open(private_key_path, "rb") as f:
                self.key = serialization.load_pem_private_key(f.read(), password=None)

    @property
    def authed(self):
        return self.key is not None

    def _headers(self, method, path):
        ts = str(int(time.time() * 1000))
        full = "/trade-api/v2" + path.split("?")[0]
        sig = self.key.sign((ts + method + full).encode(),
                            padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                                        salt_length=padding.PSS.DIGEST_LENGTH), hashes.SHA256())
        return {"KALSHI-ACCESS-KEY": self.key_id, "KALSHI-ACCESS-TIMESTAMP": ts,
                "KALSHI-ACCESS-SIGNATURE": base64.b64encode(sig).decode(),
                "Content-Type": "application/json"}

    def _req(self, method, path, auth=False, **kw):
        for attempt in range(6):
            r = self.s.request(method, self.base + path, headers=self._headers(method, path) if auth else {},
                               timeout=15, **kw)
            if r.status_code == 429:               # rate limited: back off and retry
                time.sleep(3 * (attempt + 1)); continue
            r.raise_for_status()
            return r.json()
        r.raise_for_status()

    def open_markets(self, max_pages=20, exclude_parlays=False, max_close_ts=None):
        out, cursor = [], None
        for _ in range(max_pages):
            p = {"status": "open", "limit": 1000, **({"cursor": cursor} if cursor else {}),
                 **({"mve_filter": "exclude"} if exclude_parlays else {}),
                 **({"max_close_ts": int(max_close_ts)} if max_close_ts else {})}
            d = self._req("GET", "/markets", params=p)
            out += d.get("markets", [])
            cursor = d.get("cursor")
            if not cursor:
                break
            time.sleep(0.6)                      # stay under Kalshi's read rate limit
        return out

    def series_markets(self, series):
        return self._req("GET", "/markets", params={"series_ticker": series, "status": "open",
                                                    "limit": 1000}).get("markets", [])

    def market(self, ticker):
        return self._req("GET", f"/markets/{ticker}")["market"]

    def buying_power_usd(self):
        return self._req("GET", "/portfolio/balance", auth=True)["balance"] / 100.0

    def best_ask_cents(self, ticker, side):
        m = self.market(ticker)
        return _cents(m, "yes_ask" if side == "yes" else "no_ask")

    def place_limit_buy(self, ticker, side, count, price_cents, *, live: bool):
        """Refuses to touch the network unless live=True (set only by Config.live_allowed())."""
        order = {"ticker": ticker, "action": "buy", "side": side, "type": "limit",
                 "count": count, f"{side}_price": price_cents,
                 "client_order_id": str(uuid.uuid4())}
        if not live:
            return {"dry_run": True, "order": order}
        return self._req("POST", "/portfolio/orders", auth=True, json=order)
