"""Polymarket pipeline: leaderboard -> tracked wallets -> live fills + position changes.

Two fill sources feed one queue, de-duplicated by tx hash:

* RTDS WebSocket (``wss://ws-live-data.polymarket.com``, topic ``activity/trades``):
  the global live trade tape, filtered client-side to tracked wallets. Lowest latency.
* Data API polling (``/activity?type=TRADE``) per wallet: a backstop for WS
  disconnects and missed messages.

Position snapshots (``/positions``) are diffed on a slower cadence to surface
changes that don't appear as trades (merges, splits, redemptions, transfers).
"""
from __future__ import annotations

import json
import logging
import queue
import threading
import time
from collections import OrderedDict
from typing import Callable, Iterable, Optional

import requests

from .config import PolymarketConfig
from .models import Leader, LeaderTrade

log = logging.getLogger(__name__)


class DataAPI:
    def __init__(self, base: str, session: Optional[requests.Session] = None, timeout: float = 10.0):
        self.base = base.rstrip("/")
        self.s = session or requests.Session()
        self.s.headers.setdefault("User-Agent", "copytrader/1.0")
        self.timeout = timeout

    def _get(self, path: str, **params):
        for attempt in range(4):
            try:
                r = self.s.get(f"{self.base}{path}", params=params, timeout=self.timeout)
                if r.status_code == 429 or r.status_code >= 500:
                    raise requests.HTTPError(f"{r.status_code}", response=r)
                r.raise_for_status()
                return r.json()
            except (requests.RequestException, ValueError) as e:
                if attempt == 3:
                    raise
                wait = 2 ** attempt
                log.warning("Data API %s failed (%s); retrying in %ss", path, e, wait)
                time.sleep(wait)

    def leaderboard(self, category="OVERALL", period="MONTH", order_by="PNL", limit=20) -> list[Leader]:
        rows = self._get(
            "/v1/leaderboard", category=category, timePeriod=period, orderBy=order_by, limit=limit
        )
        out = []
        for r in rows:
            out.append(
                Leader(
                    wallet=r["proxyWallet"].lower(),
                    name=r.get("userName") or r.get("pseudonym") or r["proxyWallet"][:10],
                    rank=int(r.get("rank", 0)),
                    pnl=float(r.get("pnl") or 0),
                    volume=float(r.get("vol") or 0),
                    category=category,
                )
            )
        return out

    def trades(self, wallet: str, limit: int = 50) -> list[LeaderTrade]:
        rows = self._get("/activity", user=wallet, type="TRADE", limit=limit)
        return [t for t in (parse_trade(r, "poll") for r in rows) if t]

    def positions(self, wallet: str, limit: int = 500) -> list[dict]:
        return self._get("/positions", user=wallet, limit=limit, sizeThreshold=1)


def parse_trade(r: dict, source: str) -> Optional[LeaderTrade]:
    try:
        return LeaderTrade(
            wallet=str(r["proxyWallet"]).lower(),
            side=str(r["side"]).upper(),
            asset=str(r["asset"]),
            condition_id=str(r.get("conditionId", "")),
            outcome=str(r.get("outcome", "")),
            outcome_index=int(r.get("outcomeIndex", -1)),
            size=float(r["size"]),
            price=float(r["price"]),
            timestamp=int(r["timestamp"]),
            title=str(r.get("title", "")),
            slug=str(r.get("slug", "")),
            event_slug=str(r.get("eventSlug", "")),
            tx_hash=str(r.get("transactionHash", "")),
            source=source,
        )
    except (KeyError, TypeError, ValueError):
        log.debug("Unparseable trade payload: %s", r)
        return None


class LRUSet:
    def __init__(self, cap: int = 50_000):
        self.cap = cap
        self._d: OrderedDict[str, None] = OrderedDict()
        self._lock = threading.Lock()

    def add(self, k: str) -> bool:
        """Returns True if newly added."""
        with self._lock:
            if k in self._d:
                return False
            self._d[k] = None
            if len(self._d) > self.cap:
                self._d.popitem(last=False)
            return True


class LeaderTracker:
    """Maintains the set of tracked wallets from the leaderboard."""

    def __init__(self, api: DataAPI, cfg: PolymarketConfig):
        self.api, self.cfg = api, cfg
        self.leaders: dict[str, Leader] = {}
        self._last = 0.0
        self._lock = threading.Lock()

    def refresh(self, force: bool = False) -> tuple[set, set]:
        if not force and time.time() - self._last < self.cfg.leaderboard_refresh_s:
            return set(), set()
        new: dict[str, Leader] = {}
        for cat in self.cfg.leaderboard_categories:
            board = self.api.leaderboard(cat, self.cfg.leaderboard_period,
                                         self.cfg.leaderboard_order_by, self.cfg.top_n)
            for l in board[: self.cfg.top_n]:
                new.setdefault(l.wallet, l)  # first category listed wins for display
        for i, w in enumerate(self.cfg.extra_wallets):
            w = w.lower()
            new.setdefault(w, Leader(w, f"extra-{i}", 0, 0.0, 0.0))
        with self._lock:
            added = set(new) - set(self.leaders)
            removed = set(self.leaders) - set(new)
            self.leaders = new
        self._last = time.time()
        return added, removed

    def get(self, wallet: str) -> Optional[Leader]:
        with self._lock:
            return self.leaders.get(wallet.lower())

    def wallets(self) -> list[str]:
        with self._lock:
            return list(self.leaders)


class FillStream:
    """Merges WS + polling into one de-duplicated queue of LeaderTrade."""

    def __init__(self, api: DataAPI, tracker: LeaderTracker, cfg: PolymarketConfig,
                 out: "queue.Queue[LeaderTrade]"):
        self.api, self.tracker, self.cfg, self.out = api, tracker, cfg, out
        self.seen = LRUSet()
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self.ws_connected = False

    # -- lifecycle -------------------------------------------------------
    def seed(self) -> int:
        """Mark existing history as seen so startup never replays old fills as signals."""
        n = 0
        for w in self.tracker.wallets():
            n += self._seed_wallet(w)
        return n

    def _seed_wallet(self, w: str) -> int:
        n = 0
        try:
            for t in self.api.trades(w, limit=100):
                n += self.seen.add(t.dedupe_key)
        except Exception as e:  # noqa: BLE001
            log.warning("Seed failed for %s: %s", w, e)
        return n

    def start(self) -> None:
        self._threads.append(threading.Thread(target=self._poll_loop, name="pm-poll", daemon=True))
        if self.cfg.use_websocket:
            self._threads.append(threading.Thread(target=self._ws_loop, name="pm-ws", daemon=True))
        for t in self._threads:
            t.start()

    def stop(self) -> None:
        self._stop.set()

    # -- sources ---------------------------------------------------------
    def _emit(self, t: LeaderTrade) -> None:
        if self.tracker.get(t.wallet) is None:
            return
        if self.seen.add(t.dedupe_key):
            self.out.put(t)

    def _poll_loop(self) -> None:
        while not self._stop.is_set():
            wallets = self.tracker.wallets()
            per_wallet_gap = self.cfg.poll_interval_s / max(1, len(wallets))
            for w in wallets:
                if self._stop.is_set():
                    return
                try:
                    for t in sorted(self.api.trades(w, limit=50), key=lambda x: x.timestamp):
                        self._emit(t)
                except Exception as e:  # noqa: BLE001
                    log.warning("Poll failed for %s: %s", w, e)
                self._stop.wait(per_wallet_gap)

    def _ws_loop(self) -> None:
        try:
            import websocket  # websocket-client
        except ImportError:
            log.warning("websocket-client not installed; using polling only")
            return
        backoff = 1
        sub = json.dumps({"action": "subscribe",
                          "subscriptions": [{"topic": "activity", "type": "trades"}]})
        while not self._stop.is_set():
            ws = None
            try:
                ws = websocket.create_connection(self.cfg.rtds_url, timeout=30)
                ws.send(sub)
                self.ws_connected, backoff = True, 1
                log.info("RTDS connected")
                last_ping = time.time()
                while not self._stop.is_set():
                    if time.time() - last_ping > 5:
                        ws.send("PING")
                        last_ping = time.time()
                    try:
                        msg = ws.recv()
                    except websocket.WebSocketTimeoutException:
                        continue
                    self.handle_ws_message(msg)
            except Exception as e:  # noqa: BLE001
                log.warning("RTDS error: %s (reconnect in %ss)", e, backoff)
            finally:
                self.ws_connected = False
                if ws is not None:
                    try:
                        ws.close()
                    except Exception:  # noqa: BLE001
                        pass
            self._stop.wait(backoff)
            backoff = min(backoff * 2, 60)

    def handle_ws_message(self, msg) -> None:
        if not msg or not isinstance(msg, (str, bytes)):
            return
        try:
            data = json.loads(msg)
        except ValueError:
            return  # PONG / keepalive
        if data.get("topic") not in (None, "activity") or "payload" not in data:
            return
        t = parse_trade(data["payload"], "ws")
        if t:
            self._emit(t)


class PositionTracker:
    """Snapshots each leader's open positions and reports deltas."""

    def __init__(self, api: DataAPI, min_delta_shares: float = 1.0):
        self.api = api
        self.min_delta = min_delta_shares
        self.snap: dict[str, dict[str, dict]] = {}

    def size_of(self, wallet: str, asset: str) -> Optional[float]:
        p = self.snap.get(wallet, {}).get(asset)
        return float(p["size"]) if p else (0.0 if wallet in self.snap else None)

    def poll(self, wallets: Iterable[str], on_change: Callable[[dict], None]) -> None:
        for w in wallets:
            try:
                rows = self.api.positions(w)
            except Exception as e:  # noqa: BLE001
                log.warning("Position poll failed for %s: %s", w, e)
                continue
            cur = {r["asset"]: r for r in rows}
            prev = self.snap.get(w)
            self.snap[w] = cur
            if prev is None:
                continue  # first snapshot is the baseline
            for asset in set(cur) | set(prev):
                a, b = prev.get(asset), cur.get(asset)
                old = float(a["size"]) if a else 0.0
                new = float(b["size"]) if b else 0.0
                if abs(new - old) < self.min_delta:
                    continue
                ref = b or a
                on_change({
                    "wallet": w,
                    "asset": asset,
                    "condition_id": ref.get("conditionId"),
                    "title": ref.get("title"),
                    "outcome": ref.get("outcome"),
                    "old_size": old,
                    "new_size": new,
                    "delta": new - old,
                    "cur_price": ref.get("curPrice"),
                    "avg_price": ref.get("avgPrice"),
                    "change": "opened" if not a else "closed" if not b else
                              "increased" if new > old else "decreased",
                })
