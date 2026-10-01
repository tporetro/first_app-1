"""Kalshi router: sizing, risk limits, and (live or simulated) execution.

Sizing for an entry signal::

    conviction = clamp(leader_usdc / conviction_ref_usdc, min_conviction, 1.0)
    notional   = buying_power * bankroll_fraction * conviction
    notional   = min(notional, max_order_usd, market headroom, daily headroom)
    contracts  = floor(notional / (limit_price + fee_per_contract))

The limit price never exceeds ``ask + slippage`` nor ``leader_price + max_divergence``,
and orders are IOC by default so nothing rests on the book unattended.
"""
from __future__ import annotations

import json
import logging
import math
import os
import threading
import time
import uuid
from typing import Optional

from .config import RiskConfig
from .ledger import Ledger
from .models import MarketMatch, OrderPlan, Signal

log = logging.getLogger(__name__)


def kalshi_fee(contracts: int, price: float) -> float:
    """Kalshi taker fee: ceil_to_cent(0.07 * C * P * (1 - P))."""
    return math.ceil(0.07 * contracts * price * (1 - price) * 100 - 1e-9) / 100.0


def to_book(outcome_side: str, buying: bool, outcome_price: float) -> tuple[str, float]:
    """Translate (outcome, direction, outcome price) to Kalshi V2 (book side, yes-leg price).

    bid == long YES, ask == long NO; price is always the YES-leg price.
    """
    long_yes = (outcome_side == "yes") == buying
    yes_price = outcome_price if outcome_side == "yes" else 1.0 - outcome_price
    return ("bid" if long_yes else "ask"), round(yes_price, 4)


class State:
    """Small JSON state file: our mirrored positions, daily spend, paper cash."""

    def __init__(self, path: str, paper_balance: float):
        self.path = path
        self._lock = threading.Lock()
        self.data = {"positions": {}, "daily_spend": {}, "paper_cash": paper_balance, "acted": []}
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as fh:
                self.data.update(json.load(fh))

    def save(self) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, indent=1, sort_keys=True)
        os.replace(tmp, self.path)

    @staticmethod
    def today() -> str:
        return time.strftime("%Y-%m-%d", time.gmtime())

    def spent_today(self) -> float:
        return float(self.data["daily_spend"].get(self.today(), 0.0))

    def position(self, ticker: str, side: str) -> dict:
        return self.data["positions"].get(ticker, {}).get(side, {"contracts": 0, "cost": 0.0})

    def exposure(self, ticker: str) -> float:
        return sum(p.get("cost", 0.0) for p in self.data["positions"].get(ticker, {}).values())

    def open_positions(self) -> int:
        return sum(1 for sides in self.data["positions"].values()
                   for p in sides.values() if p.get("contracts", 0) > 0)

    def acted(self, signal_id: str) -> bool:
        return signal_id in self.data["acted"]

    def record(self, signal_id: str, ticker: str, side: str, d_contracts: int, d_cost: float,
               paper: bool) -> None:
        with self._lock:
            pos = self.data["positions"].setdefault(ticker, {}).setdefault(
                side, {"contracts": 0, "cost": 0.0})
            if d_contracts >= 0:
                pos["cost"] = round(pos["cost"] + d_cost, 4)
                self.data["daily_spend"][self.today()] = round(self.spent_today() + d_cost, 4)
            else:
                held = max(1, pos["contracts"])
                pos["cost"] = round(pos["cost"] * (1 + d_contracts / held), 4)
            pos["contracts"] += d_contracts
            if paper:
                self.data["paper_cash"] = round(self.data["paper_cash"] - d_cost, 4)
            self.data["acted"] = (self.data["acted"] + [signal_id])[-5000:]
            self.save()


class Router:
    def __init__(self, kalshi, risk: RiskConfig, ledger: Ledger, state: State, live: bool):
        self.k, self.risk, self.ledger, self.state, self.live = kalshi, risk, ledger, state, live

    # -- helpers ---------------------------------------------------------
    def buying_power(self) -> tuple[float, str]:
        if self.live or self.k.authenticated:
            try:
                return self.k.balance_usd(), "kalshi_balance"
            except Exception as e:  # noqa: BLE001
                if self.live:
                    raise
                log.warning("Balance read failed (%s); using paper balance", e)
        return float(self.state.data["paper_cash"]), "paper_balance"

    def _skip(self, sig: Signal, match: Optional[MarketMatch], reason: str, **extra) -> dict:
        rec = {"decision": "SKIP", "reason": reason, "signal": sig.to_dict(),
               "match": match.to_dict() if match else None, **extra}
        self.ledger.append("decision", rec)
        log.info("SKIP %s | %s | %s", sig.title[:60], sig.side, reason)
        return rec

    # -- entry point -----------------------------------------------------
    def handle(self, sig: Signal, match: MarketMatch, leader_prev_size: Optional[float] = None) -> dict:
        if self.state.acted(sig.signal_id):
            return {"decision": "SKIP", "reason": "already acted"}
        try:
            quote = self.k.quote(match.ticker)
        except Exception as e:  # noqa: BLE001
            return self._skip(sig, match, f"quote failed: {e}")
        if quote.get("status") not in ("active", "open"):
            return self._skip(sig, match, f"Kalshi market not tradable (status={quote.get('status')})",
                              quote=quote)
        if sig.side == "BUY":
            return self._enter(sig, match, quote)
        if self.risk.mirror_exits:
            return self._exit(sig, match, quote, leader_prev_size)
        return self._skip(sig, match, "leader SELL and mirror_exits disabled")

    def _enter(self, sig: Signal, match: MarketMatch, q: dict) -> dict:
        r, side = self.risk, match.kalshi_side
        ask = q.get(f"{side}_ask")
        if ask is None or ask <= 0 or ask >= 1:
            return self._skip(sig, match, f"no {side} ask on Kalshi", quote=q)
        divergence = abs(ask - sig.vwap)
        if divergence > r.max_divergence:
            return self._skip(sig, match,
                              f"price divergence {divergence:.3f} > {r.max_divergence} "
                              f"(kalshi {side} ask {ask:.3f} vs leader {sig.vwap:.3f}) - likely mismap or stale",
                              quote=q)
        limit = round(min(ask + r.slippage, sig.vwap + r.max_divergence, r.max_price), 2)
        if ask > limit:
            return self._skip(sig, match, f"ask {ask:.3f} above limit {limit:.3f}", quote=q)
        if limit < r.min_price:
            return self._skip(sig, match, f"limit {limit:.3f} below min_price", quote=q)
        other = "no" if side == "yes" else "yes"
        if self.state.position(match.ticker, other)["contracts"] > 0:
            return self._skip(sig, match, f"already hold {other.upper()} here; leaders disagree, not hedging "
                                          "against ourselves", quote=q)
        if self.state.position(match.ticker, side)["contracts"] == 0 and \
                self.state.open_positions() >= r.max_open_positions:
            return self._skip(sig, match, f"max_open_positions ({r.max_open_positions}) reached", quote=q)

        try:
            bp, bp_src = self.buying_power()
        except Exception as e:  # noqa: BLE001
            return self._skip(sig, match, f"balance unavailable: {e}", quote=q)
        conviction = max(r.min_conviction, min(1.0, sig.usdc / r.conviction_ref_usdc))
        raw = bp * r.bankroll_fraction * conviction
        market_room = r.max_market_exposure_usd - self.state.exposure(match.ticker)
        daily_room = r.max_daily_usd - self.state.spent_today()
        notional = max(0.0, min(raw, r.max_order_usd, market_room, daily_room, bp))
        per_contract = limit + 0.07 * limit * (1 - limit) + 0.01  # price + fee + rounding buffer
        count = int(notional // per_contract)
        sizing = {
            "buying_power": round(bp, 2), "buying_power_source": bp_src,
            "bankroll_fraction": r.bankroll_fraction, "leader_usdc": round(sig.usdc, 2),
            "conviction": round(conviction, 4), "raw_notional": round(raw, 2),
            "market_room": round(market_room, 2), "daily_room": round(daily_room, 2),
            "final_notional": round(notional, 2), "ask": ask, "limit": limit,
            "divergence": round(divergence, 4),
        }
        if count < 1:
            return self._skip(sig, match, "size rounds to 0 contracts", quote=q, sizing=sizing)
        return self._execute(sig, match, q, side, True, count, limit, sizing)

    def _exit(self, sig: Signal, match: MarketMatch, q: dict, leader_prev_size: Optional[float]) -> dict:
        side = match.kalshi_side
        held = self.state.position(match.ticker, side)["contracts"]
        if held <= 0:
            return self._skip(sig, match, "leader SELL but we hold no mirrored position")
        frac = 1.0 if not leader_prev_size else min(1.0, sig.size / leader_prev_size)
        count = min(held, max(1, math.ceil(held * frac)))
        bid = q.get(f"{side}_bid")
        if bid is None or bid <= 0:
            return self._skip(sig, match, f"no {side} bid to exit into", quote=q)
        limit = round(max(0.01, bid - self.risk.slippage), 2)
        sizing = {"held": held, "leader_sold": sig.size, "leader_prev_size": leader_prev_size,
                  "exit_fraction": round(frac, 4), "bid": bid, "limit": limit}
        return self._execute(sig, match, q, side, False, count, limit, sizing)

    def _execute(self, sig, match, q, side, buying, count, limit, sizing) -> dict:
        book_side, book_price = to_book(side, buying, limit)
        fee = kalshi_fee(count, limit)
        plan = OrderPlan(
            ticker=match.ticker, outcome_side=side, action="open" if buying else "reduce",
            count=count, limit_price=limit, book_side=book_side, book_price=book_price,
            est_cost=round(count * limit, 2), est_fee=fee,
            time_in_force=self.risk.time_in_force, reduce_only=not buying,
            client_order_id=str(uuid.uuid4()), sizing=sizing,
        )
        rec = {"decision": "ORDER", "live": self.live, "signal": sig.to_dict(),
               "match": match.to_dict(), "quote": q, "order": plan.to_dict()}
        self.ledger.append("order_planned", rec)
        verb = "BUY" if buying else "SELL"
        tag = "LIVE" if self.live else "DRY-RUN"
        log.info("[%s] %s %d %s %s @ %.2f (~$%.2f + $%.2f fee) | mirrors %s on '%s'",
                 tag, verb, count, match.ticker, side.upper(), limit, plan.est_cost, fee,
                 sig.leader_name, sig.title[:60])

        if not self.live:
            signed = count if buying else -count
            self.state.record(sig.signal_id, match.ticker, side, signed,
                              (plan.est_cost + fee) if buying else -(plan.est_cost - fee), paper=True)
            return rec

        try:
            resp = self.k.create_order(plan.to_api_payload())
        except Exception as e:  # noqa: BLE001
            self.ledger.append("order_error", {"client_order_id": plan.client_order_id, "error": str(e)})
            log.error("Order failed: %s", e)
            rec["error"] = str(e)
            return rec
        order = resp.get("order", resp)
        filled = order.get("fill_count_fp", order.get("fill_count"))
        if filled is None and order.get("remaining_count") is not None:
            filled = count - float(order["remaining_count"])
        filled = int(float(filled or 0))
        self.ledger.append("order_submitted", {"client_order_id": plan.client_order_id,
                                               "filled": filled, "response": resp})
        if filled:
            cost = filled * limit + kalshi_fee(filled, limit)
            self.state.record(sig.signal_id, match.ticker, side, filled if buying else -filled,
                              cost if buying else -cost, paper=False)
        rec["response"] = resp
        return rec
