import os, sys, time, random
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from lab import db, strategy as S

def mk(c, mid_id, mid, p_ai, venue="kalshi", close="2099-01-01T00:00:00Z"):
    db.upsert_market(c, venue, mid_id, "Q " + mid_id, "YES", "r", close)
    db.add_snapshot(c, venue, mid_id, mid - 0.01, mid + 0.01, mid, 100)
    c.execute("INSERT INTO forecasts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
              (time.time(), venue, mid_id, "m", p_ai, "m", "", "[]", mid, mid + .01, mid - .01, 1, 1, 0.01))

def test_combine_moves_toward_signals_but_shrinks(tmp_path):
    c = db.connect(str(tmp_path / "s.db")); mk(c, "A", 0.50, 0.80)
    f = S.features_for(c, c.execute("select * from markets").fetchone())
    p = S.combine(f, S.PRIOR)
    assert 0.50 < p < 0.80                                  # moves toward AI, not all the way

def test_no_signal_means_market_price(tmp_path):
    f = {"mid": 0.4, "x_ai": 0, "x_xv": 0, "x_flow": 0}
    assert abs(S.combine(f, S.PRIOR) - 0.4) < 1e-9

def test_decide_trade_needs_edge_after_fees():
    assert S.decide_trade(0.52, 0.49, 0.51)[0] is None       # edge eaten by friction
    side, edge, kelly = S.decide_trade(0.70, 0.49, 0.51)
    assert side == "yes" and edge > 0.04 and 0 < kelly <= S.MAX_BET_FRAC
    assert S.decide_trade(0.30, 0.49, 0.51)[0] == "no"

def test_flow_and_cross_venue(tmp_path):
    c = db.connect(str(tmp_path / "s.db"))
    mk(c, "P1", 0.50, 0.50, venue="polymarket"); mk(c, "K1", 0.50, 0.50, venue="kalshi")
    c.execute("INSERT INTO pairs VALUES('P1','K1',1.0)")
    db.add_snapshot(c, "polymarket", "P1", .59, .61, .60, 1000)       # Polymarket says 60%
    now = time.time()
    c.execute("INSERT INTO wallet_trades VALUES('t1',?,?,?,?,?,?,?,?,?)", (int(now), "w", "BUY", "YES", .6, 5000, "t", "s", "P1"))
    c.commit()
    f = S.features_for(c, dict(c.execute("select * from markets where market_id='K1'").fetchone()), now)
    assert f["x_xv"] > 0.3 and f["x_flow"] > 0.9              # kalshi sees poly's higher price + whale buying

def test_fit_learns_informative_signal_and_gate(tmp_path):
    c = db.connect(str(tmp_path / "s.db")); rnd = random.Random(1); outcomes = {}
    for i in range(400):                                       # AI is genuinely informative
        true_p = rnd.choice([.2, .8]); mid = .5; y = 1 if rnd.random() < true_p else 0
        mk(c, f"M{i}", mid, true_p); outcomes[f"M{i}"] = y
    c.commit(); S.decide_all(c)                                # decide BEFORE outcomes are known
    for k, y in outcomes.items():
        c.execute("UPDATE markets SET resolved=1, outcome=? WHERE market_id=?", (y, k))
    c.commit()
    w0 = S.current_weights(c); w = S.fit_weights(c)
    assert w["w_ai"] > w0["w_ai"]                              # earned more weight
    ev = S.evaluate(c); assert ev["n"] == 400 and ev["brier_combined"] < ev["brier_market"]

def test_gate_blocks_on_noise(tmp_path):
    c = db.connect(str(tmp_path / "s.db")); rnd = random.Random(2)
    for i in range(400):                                       # AI is pure noise
        mk(c, f"N{i}", .5, rnd.choice([.2, .8]))
    c.commit(); S.decide_all(c)
    for i in range(400):
        c.execute("UPDATE markets SET resolved=1, outcome=? WHERE market_id=?", (rnd.randint(0, 1), f"N{i}"))
    c.commit()
    assert S.evaluate(c)["ready_for_real_money"] is False
