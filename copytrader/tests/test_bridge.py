import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
import pytest
from lab import db, bridge, strategy
from copytrader.ledger import Ledger

PROD, DEMO = "https://api.elections.kalshi.com/trade-api/v2", "https://demo-api.kalshi.co/trade-api/v2"
LIVE_TOKEN = "YES_SEND_REAL_ORDERS"


class FakeK:
    """Stand-in for the Kalshi client. Records what the bridge would send; never touches the network."""
    def __init__(self, authed=True, ask=50, status="open"):
        self.authed, self.ask, self.status, self.sent = authed, ask, status, []
    def buying_power_usd(self): return 1000.0
    def market(self, t): return {"status": self.status, "yes_ask_dollars": f"{self.ask/100:.4f}", "no_ask_dollars": "0.5000"}
    def place_limit_buy(self, t, side, n, p, *, live):
        assert live is True                          # bridge only calls this when every lock is open
        self.sent.append((t, side, n, p)); return {"order": {"status": "resting"}}


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    for v in ("KALSHI_LIVE_CONFIRM", "KALSHI_PROD_CONFIRM"):
        monkeypatch.delenv(v, raising=False)
    c = db.connect(str(tmp_path / "b.db")); now = time.time(); day = bridge._today(now)
    db.upsert_market(c, "kalshi", "T1", "Q", "YES", "", "2099-01-01T00:00:00Z")
    c.execute("INSERT INTO features VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
              (now, day, "kalshi", "T1", .5, .49, .51, .7, 0, 0, 0, .70, "yes", .15, .02))
    c.commit()
    return c, Ledger(str(tmp_path / "led.jsonl")), now


def open_gate(mp): mp.setattr(strategy, "evaluate", lambda c: {"ready_for_real_money": True})
def all_confirm(mp):
    mp.setenv("KALSHI_LIVE_CONFIRM", LIVE_TOKEN); mp.setenv("KALSHI_PROD_CONFIRM", bridge.PROD_CONFIRM)


def test_gate_closed_blocks_even_with_all_flags(env, monkeypatch):
    c, led, now = env; all_confirm(monkeypatch); k = FakeK()
    r = bridge.route(c, k, PROD, led, live=True, now=now)
    assert r["sent"] == 0 and r["planned_blocked"] == 1 and any("gate" in b for b in r["blocked_by"])
    assert k.sent == []


def test_gate_cannot_be_skipped_on_prod(env, monkeypatch):
    c, led, now = env; all_confirm(monkeypatch); k = FakeK()
    assert bridge.route(c, k, PROD, led, live=True, demo_skip_gate=True, now=now)["sent"] == 0
    assert k.sent == []


def test_demo_skip_gate_works_only_on_demo(env, monkeypatch):
    c, led, now = env; monkeypatch.setenv("KALSHI_LIVE_CONFIRM", LIVE_TOKEN); k = FakeK()
    r = bridge.route(c, k, DEMO, led, live=True, demo_skip_gate=True, now=now)
    assert r["sent"] == 1 and k.sent[0][0] == "T1"


def test_every_individual_lock_blocks(env, monkeypatch):
    c, led, now = env; open_gate(monkeypatch)
    all_confirm(monkeypatch)                                              # missing --live
    assert bridge.route(c, FakeK(), PROD, led, live=False, now=now)["sent"] == 0
    monkeypatch.delenv("KALSHI_LIVE_CONFIRM")                             # missing live confirm
    assert bridge.route(c, FakeK(), PROD, led, live=True, now=now)["sent"] == 0
    monkeypatch.setenv("KALSHI_LIVE_CONFIRM", LIVE_TOKEN); monkeypatch.delenv("KALSHI_PROD_CONFIRM")
    assert bridge.route(c, FakeK(), PROD, led, live=True, now=now)["sent"] == 0   # missing prod confirm
    all_confirm(monkeypatch)                                              # no credentials
    assert bridge.route(c, FakeK(authed=False), PROD, led, live=True, now=now)["sent"] == 0
    open(bridge.KILL_FILE, "w").write("x")                                # kill switch
    assert bridge.route(c, FakeK(), PROD, led, live=True, now=now)["sent"] == 0
    os.remove(bridge.KILL_FILE)


def test_all_locks_open_sends_once_and_is_idempotent(env, monkeypatch):
    c, led, now = env; open_gate(monkeypatch); all_confirm(monkeypatch); k = FakeK()
    assert bridge.route(c, k, PROD, led, live=True, now=now)["sent"] == 1
    n, price = k.sent[0][2], k.sent[0][3]
    assert n * price / 100 <= 20.0 + 1e-9                                 # 2% Kelly cap of $1000
    assert bridge.route(c, k, PROD, led, live=True, now=now)["sent"] == 0 # one order per market per day
    assert led.verify()


def test_fresh_price_edge_recheck(env, monkeypatch):
    c, led, now = env; open_gate(monkeypatch); all_confirm(monkeypatch)
    assert bridge.route(c, FakeK(ask=68), PROD, led, live=True, now=now)["sent"] == 0   # market moved to our fair value


def test_stale_decision_and_closed_market_skipped(env, monkeypatch):
    c, led, now = env; open_gate(monkeypatch); all_confirm(monkeypatch)
    assert bridge.route(c, FakeK(), PROD, led, live=True, now=now + 7 * 3600)["sent"] == 0
    assert bridge.route(c, FakeK(status="closed"), PROD, led, live=True, now=now)["sent"] == 0


def test_daily_cap(env, monkeypatch):
    c, led, now = env; open_gate(monkeypatch); all_confirm(monkeypatch)
    assert bridge.route(c, FakeK(), PROD, led, live=True, limits={"max_daily_usd": 0.0}, now=now)["sent"] == 0


def test_drawdown_breaker(env, monkeypatch):
    c, led, now = env; open_gate(monkeypatch); all_confirm(monkeypatch)
    db.upsert_market(c, "kalshi", "OLD", "Q", "YES", "", "x")
    c.execute("UPDATE markets SET resolved=1, outcome=0 WHERE market_id='OLD'")
    c.execute("INSERT INTO orders VALUES(?,?,?,?,?,?,?,?,?,?,?)",
              (now - 3600, "2020-01-01", "kalshi", "OLD", "yes", 200, .5, 100, 1, .7, ""))
    c.commit()                                                            # lost $100 = 10% of a $1000 bankroll
    r = bridge.route(c, FakeK(), PROD, led, live=True, now=now)
    assert r["sent"] == 0 and any("breaker" in b for b in r["blocked_by"])
