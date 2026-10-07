import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from copytrader.config import Config
from copytrader.ledger import Ledger
from copytrader.mapping import Mapper
from copytrader.engine import Engine
from copytrader.risk import Risk

KM = [
 {"ticker": "FED-DEC-CUT", "title": "Will the Fed cut rates in December 2026?", "close_time": "2026-12-10T00:00:00Z"},
 {"ticker": "FED-DEC-HOLD", "title": "Will the Fed not cut rates in December 2026?", "close_time": "2026-12-10T00:00:00Z"},
 {"ticker": "BTC-100K", "title": "Will Bitcoin be above 100000 on Dec 31 2026?", "close_time": "2026-12-31T00:00:00Z"},
 {"ticker": "BTC-150K", "title": "Will Bitcoin be above 150000 on Dec 31 2026?", "close_time": "2026-12-31T00:00:00Z"},
]

def test_mapping_respects_numbers_and_negation():
    m = Mapper(KM, min_score=0.6)
    assert m.match("Will Bitcoin be above 150000 on Dec 31 2026?")[0]["ticker"] == "BTC-150K"
    assert m.match("Will the Fed cut rates in December 2026?")[0]["ticker"] == "FED-DEC-CUT"
    assert m.match("Will Bitcoin be above 120000 on Dec 31 2026?")[0] is None
    assert m.match("Will Lakers win the 2026 title?")[0] is None

def test_ledger_tamper_detection(tmp_path):
    l = Ledger(str(tmp_path / "l.jsonl")); l.append("a", {"x": 1}); l.append("b", {"y": 2})
    assert l.verify()
    lines = open(l.path).read().replace('"x": 1', '"x": 9'); open(l.path, "w").write(lines)
    assert not Ledger(l.path).verify()

def test_risk_caps():
    cfg = Config(bankroll_fraction_per_trade=0.5, max_trade_usd=10, max_open_usd_per_market=12)
    r = Risk(cfg)
    n, _ = r.size(1000, 50, "T"); assert n == 20          # capped by $10 / $0.50
    r.record("T", 10); n, _ = r.size(1000, 50, "T"); assert n == 4   # $2 left in market
    assert Risk(cfg).size(1000, 0, "T")[0] == 0

class FakePoly:
    def __init__(self, trades): self.t = trades
    def top_traders(self, n, p): return [{"wallet": "0xabc", "name": "w", "pnl": 1}]
    def recent_trades(self, w): return self.t

class FakeKalshi:
    authed = False
    def __init__(self): self.placed = []
    def market(self, t): return {"ticker": t, "yes_ask": 52, "no_ask": 49}
    def place_limit_buy(self, t, side, n, p, *, live):
        assert live is False                      # dry-run must never request live
        return {"dry_run": True}

def mk(tmp_path, trades):
    cfg = Config(ledger_path=str(tmp_path / "l.jsonl"), state_path=str(tmp_path / "s.json"))
    poly = FakePoly([])
    eng = Engine(cfg, poly, FakeKalshi(), lambda: Mapper(KM, min_score=0.6))
    eng.start(); poly.t = trades; return eng

def tr(**k):
    d = {"id": "h1:a", "wallet": "0xabc", "ts": 1000, "side": "BUY", "outcome": "Yes", "price": 0.50,
         "usdc": 500, "title": "Will the Fed cut rates in December 2026?", "condition_id": "c"}
    d.update(k); return d

def kinds(eng): return [r["kind"] for r in eng.ledger.records()]

def test_dry_run_plans_order_not_live(tmp_path):
    eng = mk(tmp_path, [tr()]); eng.tick(now=1010)
    assert "order_planned" in kinds(eng) and "order_live" not in kinds(eng)
    assert eng.ledger.verify()

def test_history_before_start_not_copied(tmp_path):
    cfg = Config(ledger_path=str(tmp_path / "l.jsonl"), state_path=str(tmp_path / "s.json"))
    eng = Engine(cfg, FakePoly([tr()]), FakeKalshi(), lambda: Mapper(KM, min_score=0.6))
    eng.start(); eng.tick(now=1010)
    assert "order_planned" not in kinds(eng)

def test_filters(tmp_path):
    bad = [tr(side="SELL"), tr(usdc=5), tr(ts=1), tr(price=0.30), tr(title="Unrelated thing?")]
    for n, t in enumerate(bad):
        eng = mk(tmp_path / f"c{n}", [t]) if (tmp_path / f"c{n}").mkdir() is None else None
        eng.tick(now=1010)
        assert "order_planned" not in kinds(eng), t
        assert "skip" in kinds(eng)

def test_live_requires_confirm(monkeypatch):
    monkeypatch.delenv("KALSHI_LIVE_CONFIRM", raising=False)
    assert not Config(live=True).live_allowed()
    monkeypatch.setenv("KALSHI_LIVE_CONFIRM", "YES_SEND_REAL_ORDERS")
    assert Config(live=True).live_allowed() and not Config(live=False).live_allowed()
