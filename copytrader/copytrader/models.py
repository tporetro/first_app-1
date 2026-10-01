"""Plain data objects passed between the pipeline layers."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Optional


@dataclass(frozen=True)
class Leader:
    """A tracked Polymarket wallet pulled from the leaderboard."""

    wallet: str  # lower-cased proxy wallet
    name: str
    rank: int
    pnl: float
    volume: float


@dataclass(frozen=True)
class LeaderTrade:
    """A single on-chain fill by a tracked wallet (from the Data API or RTDS stream)."""

    wallet: str
    side: str  # "BUY" | "SELL"
    asset: str  # CTF token id
    condition_id: str
    outcome: str  # "Yes", "No", or a named outcome ("Up", "Trump", ...)
    outcome_index: int
    size: float  # shares
    price: float  # 0..1
    timestamp: int  # unix seconds
    title: str
    slug: str
    event_slug: str
    tx_hash: str
    source: str = "poll"  # "poll" | "ws"

    @property
    def usdc(self) -> float:
        return self.size * self.price

    @property
    def dedupe_key(self) -> str:
        return f"{self.tx_hash}:{self.asset}:{self.wallet}:{self.side}:{self.size:.6f}"

    def to_dict(self) -> dict:
        d = asdict(self)
        d["usdc"] = round(self.usdc, 6)
        return d


@dataclass
class Signal:
    """One or more leader fills on the same (wallet, asset, side), aggregated."""

    wallet: str
    leader_name: str
    leader_rank: int
    side: str
    asset: str
    condition_id: str
    outcome: str
    title: str
    slug: str
    event_slug: str
    size: float = 0.0
    usdc: float = 0.0
    first_ts: int = 0
    last_ts: int = 0
    fills: int = 0
    tx_hashes: list = field(default_factory=list)

    @property
    def vwap(self) -> float:
        return self.usdc / self.size if self.size else 0.0

    @property
    def signal_id(self) -> str:
        return f"{self.wallet}:{self.asset}:{self.side}:{self.first_ts}:{self.fills}"

    def add(self, t: LeaderTrade) -> None:
        self.size += t.size
        self.usdc += t.usdc
        self.first_ts = t.timestamp if not self.first_ts else min(self.first_ts, t.timestamp)
        self.last_ts = max(self.last_ts, t.timestamp)
        self.fills += 1
        self.tx_hashes.append(t.tx_hash)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["vwap"] = round(self.vwap, 6)
        d["signal_id"] = self.signal_id
        return d


@dataclass(frozen=True)
class KalshiCandidate:
    ticker: str
    event_ticker: str
    series_ticker: str
    category: str
    title: str
    event_title: str
    yes_sub_title: str
    no_sub_title: str
    close_time: str
    rules: str = ""


@dataclass
class MarketMatch:
    """Result of the semantic mapping layer."""

    ticker: str
    kalshi_side: str  # "yes" | "no" -- the Kalshi outcome that mirrors the leader's position
    score: float
    method: str  # "override" | "semantic"
    kalshi_title: str
    runner_up: Optional[str] = None
    runner_up_score: float = 0.0
    reasons: list = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class OrderPlan:
    """A fully-specified Kalshi order, before (or instead of) submission."""

    ticker: str
    outcome_side: str  # "yes" | "no"
    action: str  # "open" | "reduce"
    count: int
    limit_price: float  # price of the outcome we are buying, in dollars (0..1)
    book_side: str  # Kalshi V2 "bid" (long yes) | "ask" (long no)
    book_price: float  # yes-leg price sent to Kalshi
    est_cost: float
    est_fee: float
    time_in_force: str
    reduce_only: bool
    client_order_id: str
    sizing: dict = field(default_factory=dict)

    def to_api_payload(self) -> dict:
        return {
            "ticker": self.ticker,
            "side": self.book_side,
            "count": f"{self.count:.2f}",
            "price": f"{self.book_price:.4f}",
            "time_in_force": self.time_in_force,
            "reduce_only": self.reduce_only,
            "post_only": False,
            "self_trade_prevention_type": "taker_at_cross",
            "client_order_id": self.client_order_id,
        }

    def to_dict(self) -> dict:
        d = asdict(self)
        d["api_payload"] = self.to_api_payload()
        return d
