"""Deterministic sizing + limits. No agent/LLM can override these."""
import math, time
from datetime import datetime, timezone


class Risk:
    def __init__(self, cfg):
        self.cfg = cfg
        self.spent_by_market = {}
        self.spent_today = 0.0
        self._day = datetime.now(timezone.utc).date()

    def _roll(self):
        d = datetime.now(timezone.utc).date()
        if d != self._day:
            self._day, self.spent_today = d, 0.0

    def size(self, bankroll_usd, price_cents, ticker):
        """Return (contracts, reason). contracts==0 means skip."""
        self._roll()
        c = self.cfg
        if not (1 <= price_cents <= 99):
            return 0, "price out of range"
        budget = min(bankroll_usd * c.bankroll_fraction_per_trade, c.max_trade_usd,
                     c.max_open_usd_per_market - self.spent_by_market.get(ticker, 0.0),
                     c.max_daily_usd - self.spent_today)
        if budget <= 0:
            return 0, "risk limit reached"
        n = math.floor(budget / (price_cents / 100.0))
        return (n, "ok") if n >= 1 else (0, "budget below one contract")

    def record(self, ticker, usd):
        self._roll()
        self.spent_by_market[ticker] = self.spent_by_market.get(ticker, 0.0) + usd
        self.spent_today += usd
