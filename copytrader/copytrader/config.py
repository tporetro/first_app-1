from dataclasses import dataclass
import os

POLYMARKET_DATA_API = "https://data-api.polymarket.com"
KALSHI_PROD = "https://api.elections.kalshi.com/trade-api/v2"
KALSHI_DEMO = "https://demo-api.kalshi.co/trade-api/v2"
LIVE_CONFIRM_TOKEN = "YES_SEND_REAL_ORDERS"


@dataclass
class Config:
    top_n: int = 20
    leaderboard_period: str = "WEEK"        # DAY | WEEK | MONTH | ALL
    poll_seconds: int = 20
    # signal filters
    min_source_usdc: float = 200.0          # ignore small fills by the tracked wallet
    max_signal_age_s: int = 300             # stale fills are not copied
    max_slippage_cents: int = 4             # Kalshi ask may be at most this above their fill price
    min_match_score: float = 0.72           # semantic market-mapping threshold
    # sizing / risk (fractions of Kalshi buying power)
    bankroll_fraction_per_trade: float = 0.01
    max_trade_usd: float = 25.0
    max_open_usd_per_market: float = 50.0
    max_daily_usd: float = 150.0
    simulated_bankroll_usd: float = 1000.0  # used when there is no Kalshi auth (dry-run)
    # infra
    kalshi_base_url: str = KALSHI_DEMO
    kalshi_key_id: str = ""
    kalshi_private_key_path: str = ""
    ledger_path: str = "ledger/ledger.jsonl"
    state_path: str = "state/seen.json"
    overrides_path: str = "mapping_overrides.json"
    live: bool = False

    @classmethod
    def from_env(cls, **kw) -> "Config":
        c = cls(**kw)
        c.kalshi_base_url = os.getenv("KALSHI_BASE_URL", c.kalshi_base_url)
        c.kalshi_key_id = os.getenv("KALSHI_KEY_ID", "")
        c.kalshi_private_key_path = os.getenv("KALSHI_PRIVATE_KEY_PATH", "")
        return c

    def live_allowed(self) -> bool:
        return self.live and os.getenv("KALSHI_LIVE_CONFIRM") == LIVE_CONFIRM_TOKEN
