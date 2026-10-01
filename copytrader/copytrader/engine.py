"""Orchestrates: leaderboard -> fills -> aggregation -> mapping -> routing -> ledger."""
from __future__ import annotations

import logging
import queue
import threading
import time
from typing import Optional

from .config import Config
from .ledger import Ledger
from .mapping import MarketMapper
from .models import LeaderTrade, Signal
from .polymarket import DataAPI, FillStream, LeaderTracker, PositionTracker
from .router import Router, State

log = logging.getLogger(__name__)


class Aggregator:
    """Leaders often split one decision into many fills; merge them per (wallet, asset, side)."""

    def __init__(self, window_s: float):
        self.window = window_s
        self.pending: dict[tuple, Signal] = {}
        self.opened: dict[tuple, float] = {}

    def add(self, t: LeaderTrade, leader_name: str, leader_rank: int) -> None:
        key = (t.wallet, t.asset, t.side)
        sig = self.pending.get(key)
        if sig is None:
            sig = Signal(t.wallet, leader_name, leader_rank, t.side, t.asset, t.condition_id,
                         t.outcome, t.title, t.slug, t.event_slug)
            self.pending[key] = sig
            self.opened[key] = time.time()
        sig.add(t)

    def flush(self, force: bool = False) -> list[Signal]:
        now, out = time.time(), []
        for key in list(self.pending):
            if force or now - self.opened[key] >= self.window:
                out.append(self.pending.pop(key))
                self.opened.pop(key)
        return out


class Engine:
    def __init__(self, cfg: Config, kalshi, ledger: Ledger, live: bool, base_dir: str = ".",
                 data_api: Optional[DataAPI] = None):
        self.cfg, self.live, self.ledger = cfg, live, ledger
        self.api = data_api or DataAPI(cfg.polymarket.data_api)
        self.tracker = LeaderTracker(self.api, cfg.polymarket)
        self.q: "queue.Queue[LeaderTrade]" = queue.Queue()
        self.stream = FillStream(self.api, self.tracker, cfg.polymarket, self.q)
        self.positions = PositionTracker(self.api)
        self.mapper = MarketMapper(cfg.mapping, kalshi, base_dir)
        self.state = State(cfg.state_path, cfg.risk.paper_balance_usd)
        self.router = Router(kalshi, cfg.risk, ledger, self.state, live)
        self.agg = Aggregator(cfg.polymarket.aggregation_window_s)
        self._stop = threading.Event()
        self.stats = {"fills": 0, "signals": 0, "mapped": 0, "orders": 0, "skips": 0}

    # -- setup -----------------------------------------------------------
    def bootstrap(self) -> None:
        added, _ = self.tracker.refresh(force=True)
        board = sorted((self.tracker.get(w) for w in self.tracker.wallets()), key=lambda l: l.rank)
        self.ledger.append("leaderboard", {
            "category": self.cfg.polymarket.leaderboard_category,
            "period": self.cfg.polymarket.leaderboard_period,
            "leaders": [l.__dict__ for l in board],
        })
        for l in board:
            log.info("Tracking #%-2d %-24s pnl=$%-12s %s", l.rank, l.name[:24], f"{l.pnl:,.0f}", l.wallet)
        n = self.mapper.refresh_index(force=True)
        self.ledger.append("kalshi_index", {"markets": n, "categories": self.cfg.mapping.kalshi_categories})
        seeded = self.stream.seed()
        log.info("Seeded %d historical fills as already-seen (never traded on)", seeded)
        self.positions.poll(self.tracker.wallets(), lambda c: None)  # baseline snapshot

    # -- main loop -------------------------------------------------------
    def process_trade(self, t: LeaderTrade) -> None:
        self.stats["fills"] += 1
        leader = self.tracker.get(t.wallet)
        age = time.time() - t.timestamp
        self.ledger.append("leader_fill", {**t.to_dict(), "leader": leader.name if leader else None,
                                           "age_s": round(age, 1)})
        if age > self.cfg.polymarket.signal_max_age_s:
            log.debug("Stale fill (%.0fs) ignored", age)
            return
        self.agg.add(t, leader.name if leader else "?", leader.rank if leader else 0)

    def process_signal(self, sig: Signal) -> Optional[dict]:
        self.stats["signals"] += 1
        if sig.usdc < self.cfg.polymarket.min_leader_usdc:
            log.debug("Signal below min_leader_usdc ($%.0f): %s", sig.usdc, sig.title)
            return None
        if time.time() - sig.last_ts > self.cfg.polymarket.signal_max_age_s + self.cfg.polymarket.aggregation_window_s:
            return None
        match, reasons = self.mapper.map(sig.title, sig.outcome, sig.condition_id, sig.slug, sig.event_slug)
        if match is None:
            self.stats["skips"] += 1
            self.ledger.append("unmapped", {"signal": sig.to_dict(), "reasons": reasons})
            log.info("UNMAPPED %s %s '%s' (%s)", sig.side, sig.outcome, sig.title[:70], reasons[-1])
            return None
        self.stats["mapped"] += 1
        prev = self.positions.size_of(sig.wallet, sig.asset)
        leader_prev = (prev + sig.size) if (prev is not None and sig.side == "SELL") else None
        res = self.router.handle(sig, match, leader_prev)
        self.stats["orders" if res.get("decision") == "ORDER" else "skips"] += 1
        return res

    def on_position_change(self, change: dict) -> None:
        self.ledger.append("position_change", change)
        log.info("POSITION %s %s %+.1f sh '%s' (%s)", change["wallet"][:10], change["change"],
                 change["delta"], (change.get("title") or "")[:60], change.get("outcome"))

    def run(self, once: bool = False, duration_s: Optional[float] = None) -> None:
        self.bootstrap()
        self.stream.start()
        started = time.time()
        next_pos = time.time() + self.cfg.polymarket.position_poll_interval_s
        next_stats = time.time() + 300
        try:
            while not self._stop.is_set():
                try:
                    t = self.q.get(timeout=1.0)
                    self.process_trade(t)
                except queue.Empty:
                    pass
                for sig in self.agg.flush():
                    self.process_signal(sig)
                now = time.time()
                if now >= next_pos:
                    self.positions.poll(self.tracker.wallets(), self.on_position_change)
                    next_pos = now + self.cfg.polymarket.position_poll_interval_s
                added, removed = self.tracker.refresh()
                if added or removed:
                    self.ledger.append("leaderboard_change", {"added": sorted(added), "removed": sorted(removed)})
                    for w in added:
                        self.stream._seed_wallet(w)
                self.mapper.refresh_index()
                if now >= next_stats:
                    log.info("stats %s ws=%s", self.stats, self.stream.ws_connected)
                    next_stats = now + 300
                if once and now - started > self.cfg.polymarket.aggregation_window_s + 5:
                    break
                if duration_s and now - started > duration_s:
                    break
        except KeyboardInterrupt:
            log.info("Interrupted")
        finally:
            self.stream.stop()
            for sig in self.agg.flush(force=True):
                self.process_signal(sig)
            self.ledger.append("shutdown", {"stats": self.stats})
            log.info("Stopped. %s", self.stats)

    def stop(self) -> None:
        self._stop.set()
