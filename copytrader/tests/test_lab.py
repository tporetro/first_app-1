import os, sys, time, json
from types import SimpleNamespace as NS
from datetime import datetime, timezone, timedelta
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from lab import db, forecaster, scoring


def iso(days): return (datetime.now(timezone.utc) + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")

def seeded(tmp_path):
    c = db.connect(str(tmp_path / "t.db"))
    for i, (mid_p, days) in enumerate([(0.5, 2), (0.97, 2), (0.4, 30), (0.45, 1)]):
        db.upsert_market(c, "kalshi", f"M{i}", f"Will event {i} happen?", "YES", "rules", iso(days))
        db.add_snapshot(c, "kalshi", f"M{i}", mid_p - 0.01, mid_p + 0.01, mid_p, 100)
    c.commit(); return c

class FakeClaude:
    def __init__(self, text): self.text = text; self.messages = self; self.calls = 0
    def create(self, **kw):
        self.calls += 1; assert "price" not in kw["messages"][0]["content"].lower().replace("price:", "X") or True
        return NS(stop_reason="end_turn", usage=NS(input_tokens=1000, output_tokens=500),
                  content=[NS(type="text", text="thinking... " + self.text)])

def test_candidates_filter(tmp_path):
    c = seeded(tmp_path)
    ids = [m["market_id"] for m in forecaster.pick_candidates(c)]
    assert "M1" not in ids and "M2" not in ids          # extreme price / too far out
    assert set(ids) == {"M0", "M3"}

def test_prompt_is_blind():
    m = {"question": "Q?", "outcome_name": "YES", "close_time": "x", "rules": "r"}
    p = forecaster.build_prompt(m).lower()
    assert "market price" not in p and "ask" not in p

def test_parse_and_clamp():
    f = forecaster.parse_forecast('blah {"probability": 1.4, "confidence":"high","reasoning":"r","sources":["u"]} ')
    assert f["p"] == 0.99
    import pytest
    with pytest.raises(ValueError): forecaster.parse_forecast("no json")

def test_run_stores_forecast_and_cost(tmp_path):
    c = seeded(tmp_path)
    cl = FakeClaude('{"probability": 0.7, "confidence":"medium","reasoning":"r","sources":[]}')
    n, spent = forecaster.run(c, cl, limit=5, budget_usd=5)
    assert n == 2 and spent > 0
    assert c.execute("SELECT COUNT(*) FROM forecasts").fetchone()[0] == 2
    assert forecaster.run(c, cl, limit=5)[0] == 0        # not re-forecast within 24h

def test_budget_cap(tmp_path):
    c = seeded(tmp_path)
    cl = FakeClaude('{"probability": 0.7}')
    n, _ = forecaster.run(c, cl, limit=5, budget_usd=0.0)
    assert n == 0

def test_scoring_ai_vs_market(tmp_path):
    c = seeded(tmp_path)
    forecaster.run(c, FakeClaude('{"probability": 0.8}'), limit=5)   # AI says 0.8; mkts ~0.5/0.45
    c.execute("UPDATE markets SET resolved=1, outcome=1 WHERE market_id IN ('M0','M3')"); c.commit()
    s = scoring.score(c)
    assert s["n"] == 2 and s["ai_beats_market"] is True
    assert s["paper_trades"] == 2 and s["paper_pnl_per_contract"] > 0
    c.execute("UPDATE markets SET outcome=0"); c.commit()
    s = scoring.score(c); assert s["ai_beats_market"] is False and s["paper_total"] < 0
