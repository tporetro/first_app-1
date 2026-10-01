"""Configuration: JSON file + environment overrides. Safe defaults throughout."""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field, fields, is_dataclass
from typing import Optional

LIVE_CONFIRM_ENV = "COPYTRADER_LIVE_CONFIRM"
LIVE_CONFIRM_VALUE = "I_ACCEPT_REAL_MONEY_RISK"

KALSHI_BASE_URLS = {
    "prod": "https://api.elections.kalshi.com/trade-api/v2",
    "demo": "https://external-api.demo.kalshi.co/trade-api/v2",
}


@dataclass
class PolymarketConfig:
    data_api: str = "https://data-api.polymarket.com"
    rtds_url: str = "wss://ws-live-data.polymarket.com"
    # Track the top_n of EACH leaderboard (specialists beat the overall board, which is mostly sports).
    # Valid: OVERALL POLITICS FINANCE ECONOMICS CRYPTO TECH CULTURE WEATHER SPORTS MENTIONS
    leaderboard_categories: list = field(default_factory=lambda: ["POLITICS", "FINANCE", "WEATHER"])
    leaderboard_period: str = "MONTH"  # DAY | WEEK | MONTH | ALL
    leaderboard_order_by: str = "PNL"  # PNL | VOL
    top_n: int = 20
    leaderboard_refresh_s: int = 3600
    use_websocket: bool = True  # RTDS live trade stream (falls back to polling only)
    poll_interval_s: float = 15.0  # per-wallet /activity poll cadence (backstop for WS)
    position_poll_interval_s: float = 120.0
    min_leader_usdc: float = 250.0  # ignore leader fills (aggregated) smaller than this
    aggregation_window_s: float = 20.0  # merge a leader's split fills into one signal
    signal_max_age_s: float = 300.0  # never act on fills older than this
    extra_wallets: list = field(default_factory=list)  # always track these too


@dataclass
class MappingConfig:
    # Market areas to copy: politics, geopolitics, economics, crypto, weather (see mapping.DOMAINS)
    domains: list = field(default_factory=lambda: ["politics", "geopolitics", "economics", "weather"])
    kalshi_categories: list = field(default_factory=list)  # empty = derived from domains
    index_refresh_s: int = 900
    min_score: float = 0.55
    min_margin: float = 0.05  # best match must beat runner-up by this much
    overrides_path: Optional[str] = "mapping_overrides.json"


@dataclass
class KalshiConfig:
    env: str = "demo"  # "demo" | "prod"
    key_id_env: str = "KALSHI_API_KEY_ID"
    private_key_path_env: str = "KALSHI_PRIVATE_KEY_PATH"
    timeout_s: float = 10.0

    @property
    def base_url(self) -> str:
        return KALSHI_BASE_URLS[self.env]


@dataclass
class RiskConfig:
    bankroll_fraction: float = 0.02  # base fraction of available buying power per signal
    conviction_ref_usdc: float = 10_000.0  # leader size that earns full conviction (1.0x)
    min_conviction: float = 0.25
    max_order_usd: float = 50.0
    max_market_exposure_usd: float = 150.0
    max_daily_usd: float = 300.0
    max_open_positions: int = 15
    slippage: float = 0.02  # max we'll pay above the current Kalshi ask
    max_divergence: float = 0.08  # |kalshi price - leader fill price|; larger => likely mismap
    min_price: float = 0.04
    max_price: float = 0.96
    mirror_exits: bool = True  # leader SELL => reduce our mirrored position
    paper_balance_usd: float = 1_000.0  # used in dry-run when no Kalshi creds are present
    time_in_force: str = "immediate_or_cancel"


@dataclass
class Config:
    polymarket: PolymarketConfig = field(default_factory=PolymarketConfig)
    mapping: MappingConfig = field(default_factory=MappingConfig)
    kalshi: KalshiConfig = field(default_factory=KalshiConfig)
    risk: RiskConfig = field(default_factory=RiskConfig)
    dry_run: bool = True
    ledger_path: str = "data/ledger.jsonl"
    state_path: str = "data/state.json"
    log_level: str = "INFO"

    def to_dict(self) -> dict:
        return asdict(self)


def _merge(dc, values: dict):
    for f in fields(dc):
        if f.name not in values:
            continue
        cur = getattr(dc, f.name)
        if is_dataclass(cur):
            _merge(cur, values[f.name])
        else:
            setattr(dc, f.name, values[f.name])
    unknown = set(values) - {f.name for f in fields(dc)}
    if unknown:
        raise ValueError(f"Unknown config keys for {type(dc).__name__}: {sorted(unknown)}")
    return dc


def load_config(path: Optional[str] = None) -> Config:
    cfg = Config()
    if path:
        with open(path, "r", encoding="utf-8") as fh:
            _merge(cfg, json.load(fh))
    if os.environ.get("KALSHI_ENV"):
        cfg.kalshi.env = os.environ["KALSHI_ENV"]
    if cfg.kalshi.env not in KALSHI_BASE_URLS:
        raise ValueError(f"kalshi.env must be one of {list(KALSHI_BASE_URLS)}")
    return cfg


def resolve_live_mode(cfg: Config, cli_live_flag: bool) -> tuple[bool, str]:
    """Live trading requires three independent opt-ins. Anything less => dry run.

    1. ``"dry_run": false`` in the config file
    2. ``--live`` on the command line
    3. env ``COPYTRADER_LIVE_CONFIRM=I_ACCEPT_REAL_MONEY_RISK``
    """
    missing = []
    if cfg.dry_run:
        missing.append('config "dry_run" is true')
    if not cli_live_flag:
        missing.append("--live flag not passed")
    if os.environ.get(LIVE_CONFIRM_ENV) != LIVE_CONFIRM_VALUE:
        missing.append(f"{LIVE_CONFIRM_ENV} != {LIVE_CONFIRM_VALUE}")
    if missing:
        return False, "DRY_RUN (" + "; ".join(missing) + ")"
    return True, f"LIVE on Kalshi {cfg.kalshi.env}"
