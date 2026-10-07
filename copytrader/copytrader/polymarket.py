"""Polymarket public Data API: leaderboard + per-wallet activity (polled).

Polymarket's websocket streams market data, not per-wallet fills, so wallet
tracking is done by polling /activity, which is public and keyless.
"""
import time
import requests
from .config import POLYMARKET_DATA_API


class PolymarketClient:
    def __init__(self, base=POLYMARKET_DATA_API, session=None):
        self.base = base
        self.s = session or requests.Session()

    def _get(self, path, **params):
        for attempt in range(6):
            r = self.s.get(f"{self.base}{path}", params=params, timeout=15)
            if r.status_code == 429:               # rate limited: back off and retry
                time.sleep(2 * (attempt + 1)); continue
            r.raise_for_status()
            return r.json()
        r.raise_for_status()

    def top_traders(self, n=20, period="WEEK", order_by="PNL"):
        rows = self._get("/v1/leaderboard", timePeriod=period, orderBy=order_by, limit=n)
        return [{"wallet": r["proxyWallet"], "name": r.get("userName") or r["proxyWallet"][:8],
                 "pnl": r.get("pnl")} for r in rows]

    def recent_trades(self, wallet, limit=50):
        rows = self._get("/activity", user=wallet, type="TRADE", limit=limit,
                         sortBy="TIMESTAMP", sortDirection="DESC")
        return [normalize_trade(r) for r in rows]

    def positions(self, wallet, limit=200):
        return self._get("/positions", user=wallet, limit=limit)


def normalize_trade(r: dict) -> dict:
    return {
        "id": f"{r.get('transactionHash')}:{r.get('asset')}",
        "wallet": r.get("proxyWallet"),
        "ts": int(r.get("timestamp", 0)),
        "side": (r.get("side") or "").upper(),          # BUY | SELL
        "outcome": (r.get("outcome") or "").strip(),     # Yes | No | named outcome
        "price": float(r.get("price", 0)),               # 0..1
        "usdc": float(r.get("usdcSize", 0)),
        "title": r.get("title", ""),
        "slug": r.get("slug", ""),
        "condition_id": r.get("conditionId", ""),
    }
