import os

import pytest

from copytrader.config import Config, LIVE_CONFIRM_ENV, LIVE_CONFIRM_VALUE, RiskConfig, resolve_live_mode
from copytrader.ledger import Ledger, iter_records
from copytrader.models import MarketMatch, Signal
from copytrader.router import Router, State, kalshi_fee, to_book


class FakeKalshi:
    def __init__(self, quote=None, balance=1000.0, authenticated=False):
        self.q = quote or {"status": "active", "yes_ask": 0.63, "yes_bid": 0.61,
                           "no_ask": 0.39, "no_bid": 0.37}
        self.balance = balance
        self.authenticated = authenticated
        self.orders = []

    def quote(self, ticker):
        return dict(self.q, ticker=ticker)

    def balance_usd(self):
        return self.balance

    def create_order(self, payload):
        self.orders.append(payload)
        return {"order": {"order_id": "o1", "fill_count": payload["count"].split(".")[0],
                          "remaining_count": 0}}


def sig(side="BUY", outcome="Yes", usdc=10000.0, price=0.62, size=None):
    s = Signal("0xabc", "whale", 1, side, "111", "0xcid", outcome, "Fed cut Oct 2026?", "slug", "ev")
    s.size = size if size is not None else usdc / price
    s.usdc = usdc
    s.first_ts = s.last_ts = 1
    s.fills = 1
    return s


def match(side="yes"):
    return MarketMatch("KXFEDDECISION-26OCT-C25", side, 0.9, "semantic", "Fed cut 25")


def make(tmp_path, live=False, **kw):
    k = kw.pop("kalshi", None) or FakeKalshi()
    risk = RiskConfig(**kw)
    led = Ledger(str(tmp_path / "l.jsonl"), "LIVE" if live else "DRY_RUN")
    st = State(str(tmp_path / "s.json"), risk.paper_balance_usd)
    return Router(k, risk, led, st, live), k, led


def test_to_book_conversions():
    assert to_book("yes", True, 0.63) == ("bid", 0.63)
    assert to_book("no", True, 0.39) == ("ask", 0.61)  # buy NO @ .39 == sell YES @ .61
    assert to_book("yes", False, 0.60) == ("ask", 0.60)
    assert to_book("no", False, 0.35) == ("bid", 0.65)


def test_fee():
    assert kalshi_fee(100, 0.5) == 1.75
    assert kalshi_fee(1, 0.5) == 0.02


def test_dry_run_never_submits_and_sizes(tmp_path):
    r, k, led = make(tmp_path)
    res = r.handle(sig(), match())
    assert res["decision"] == "ORDER" and k.orders == []
    o = res["order"]
    # 1000 * 0.02 * conviction 1.0 = $20 notional at limit 0.64 (ask .63 + .02 slip, capped by .62+.08)
    assert o["limit_price"] == 0.65 or o["limit_price"] == 0.64
    assert o["count"] * o["limit_price"] <= 20.0
    assert o["api_payload"]["side"] == "bid"
    assert [rec["kind"] for rec in iter_records(led.path)] == ["order_planned"]
    assert r.state.position("KXFEDDECISION-26OCT-C25", "yes")["contracts"] == o["count"]


def test_conviction_scales_size(tmp_path):
    r, _, _ = make(tmp_path, min_conviction=0.25)
    small = r.handle(sig(usdc=2500.0), match())["order"]["count"]
    r2, _, _ = make(tmp_path / "b", min_conviction=0.25)
    big = r2.handle(sig(usdc=10000.0), match())["order"]["count"]
    assert small < big


def test_caps(tmp_path):
    r, _, _ = make(tmp_path, kalshi=FakeKalshi(balance=1e6), bankroll_fraction=0.5, max_order_usd=10)
    o = r.handle(sig(), match())["order"]
    assert o["est_cost"] <= 10


def test_no_side_payload(tmp_path):
    r, _, _ = make(tmp_path)
    o = r.handle(sig(outcome="No", price=0.38, usdc=10000), match("no"))["order"]
    assert o["api_payload"]["side"] == "ask"
    assert abs(float(o["api_payload"]["price"]) - (1 - o["limit_price"])) < 1e-9


def test_divergence_skips(tmp_path):
    r, _, _ = make(tmp_path)
    res = r.handle(sig(price=0.30), match())  # Kalshi yes ask .63 vs leader .30
    assert res["decision"] == "SKIP" and "divergence" in res["reason"]


def test_exit_requires_position_and_reduces(tmp_path):
    r, _, _ = make(tmp_path)
    assert r.handle(sig(side="SELL"), match())["decision"] == "SKIP"
    entry = r.handle(sig(), match())["order"]
    s = sig(side="SELL", size=500)
    s.first_ts = 2
    ex = r.handle(s, match(), leader_prev_size=1000)["order"]
    assert ex["reduce_only"] and ex["action"] == "reduce"
    assert ex["count"] == -(-entry["count"] // 2)
    assert ex["api_payload"]["side"] == "ask"  # selling YES


def test_live_submits(tmp_path):
    r, k, led = make(tmp_path, live=True)
    res = r.handle(sig(), match())
    assert len(k.orders) == 1 and k.orders[0]["time_in_force"] == "immediate_or_cancel"
    kinds = [rec["kind"] for rec in iter_records(led.path)]
    assert kinds == ["order_planned", "order_submitted"]


def test_live_gate(monkeypatch):
    cfg = Config()
    monkeypatch.delenv(LIVE_CONFIRM_ENV, raising=False)
    assert resolve_live_mode(cfg, True)[0] is False  # dry_run default
    cfg.dry_run = False
    assert resolve_live_mode(cfg, False)[0] is False  # no --live
    assert resolve_live_mode(cfg, True)[0] is False  # no env confirm
    monkeypatch.setenv(LIVE_CONFIRM_ENV, LIVE_CONFIRM_VALUE)
    assert resolve_live_mode(cfg, True)[0] is True
