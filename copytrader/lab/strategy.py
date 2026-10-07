"""One combined strategy: market price + AI forecast + cross-venue gap + smart-money flow.

    logit(p) = logit(mid) + w_ai*x_ai + w_xv*x_xv + w_flow*x_flow
Each x is "how far this signal disagrees with the market, in log-odds"; weights start
as small priors and are refit (ridge toward the priors) from RESOLVED history, so a
signal only earns influence after it has actually been right. Trades are sized with
fractional Kelly under hard caps. Nothing here sends orders.
"""
import math, random, time
from datetime import datetime, timezone
from . import db
from .pairs import other_side

PRIOR = {"w_ai": 0.35, "w_xv": 0.30, "w_flow": 0.15}
FLOW_WINDOW_S, FLOW_SCALE_USD = 6 * 3600, 2000.0
MIN_EDGE, KELLY_FRACTION, MAX_BET_FRAC, SLIPPAGE = 0.04, 0.25, 0.02, 0.005


def logit(p): p = min(0.99, max(0.01, p)); return math.log(p / (1 - p))
def sigmoid(z): return 1 / (1 + math.exp(-z))
def kalshi_fee(price): return 0.07 * price * (1 - price)       # approx taker fee per $1 contract
def friction(price): return kalshi_fee(price) + SLIPPAGE


def smart_flow(c, venue, market_id, outcome_name, now=None):
    """tanh of net size-weighted tracked-wallet flow toward this market's outcome (Polymarket data)."""
    now = now or time.time()
    if venue != "polymarket":
        return 0.0
    net = 0.0
    for t in c.execute("SELECT side,outcome,usdc FROM wallet_trades WHERE condition_id=? AND ts>?",
                       (market_id, now - FLOW_WINDOW_S)):
        toward = (t["outcome"] == outcome_name)
        buy = t["side"] == "BUY"
        net += t["usdc"] * (1 if toward == buy else -1)
    return math.tanh(net / FLOW_SCALE_USD)


def current_weights(c):
    r = c.execute("SELECT w_ai,w_xv,w_flow FROM weights ORDER BY ts DESC LIMIT 1").fetchone()
    return dict(r) if r else dict(PRIOR)


def features_for(c, m, now=None):
    q = db.latest_quote(c, m["venue"], m["market_id"]); mid = db.mid_of(q)
    f = c.execute("SELECT p FROM forecasts WHERE venue=? AND market_id=? ORDER BY ts DESC LIMIT 1",
                  (m["venue"], m["market_id"])).fetchone()
    if mid is None or not f or not q or q["ask"] is None or q["bid"] is None:
        return None
    x_ai = logit(f["p"]) - logit(mid)
    x_xv = 0.0
    o = other_side(c, m["venue"], m["market_id"])
    if o:
        omid = db.mid_of(db.latest_quote(c, *o))
        if omid is not None:
            x_xv = logit(omid) - logit(mid)
    poly_id = m["market_id"] if m["venue"] == "polymarket" else (o[1] if o else None)
    pm = c.execute("SELECT outcome_name FROM markets WHERE venue='polymarket' AND market_id=?", (poly_id,)).fetchone() if poly_id else None
    x_flow = smart_flow(c, "polymarket", poly_id, pm["outcome_name"], now) if pm else 0.0
    return {"mid": mid, "bid": q["bid"], "ask": q["ask"], "p_ai": f["p"], "x_ai": x_ai, "x_xv": x_xv, "x_flow": x_flow}


def combine(feat, w):
    z = logit(feat["mid"]) + w["w_ai"] * feat["x_ai"] + w["w_xv"] * feat["x_xv"] + w["w_flow"] * feat["x_flow"]
    return sigmoid(z)


def decide_trade(p, bid, ask):
    """(side, edge, kelly_fraction_of_bankroll). side None => no trade."""
    best = (None, 0.0, 0.0)
    if ask and 0 < ask < 1:
        edge = p - ask - friction(ask)
        if edge > MIN_EDGE and edge > best[1]:
            best = ("yes", edge, KELLY_FRACTION * min(MAX_BET_FRAC / KELLY_FRACTION, (p - ask) / (1 - ask)))
    if bid is not None and 0 < bid < 1:
        cost = 1 - bid
        edge = (1 - p) - cost - friction(cost)
        if edge > MIN_EDGE and edge > best[1]:
            best = ("no", edge, KELLY_FRACTION * min(MAX_BET_FRAC / KELLY_FRACTION, ((1 - p) - cost) / (1 - cost)))
    return best


def decide_all(c, now=None):
    """Compute + log (one row per market per day) the combined decision for every forecasted market."""
    now = now or time.time(); w = current_weights(c); n = 0
    day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
    for m in c.execute("SELECT * FROM markets WHERE resolved=0").fetchall():
        f = features_for(c, m, now)
        if not f:
            continue
        p = combine(f, w); side, edge, kelly = decide_trade(p, f["bid"], f["ask"])
        c.execute("INSERT OR IGNORE INTO features VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (now, day, m["venue"], m["market_id"], f["mid"], f["bid"], f["ask"], f["p_ai"],
                   f["x_ai"], f["x_xv"], f["x_flow"], p, side, edge, kelly)); n += 1
    c.commit(); return n


def _resolved(c):
    return c.execute("""SELECT f.*, m.outcome FROM features f JOIN markets m
                        ON m.venue=f.venue AND m.market_id=f.market_id WHERE m.resolved=1""").fetchall()


def fit_weights(c, lam=20.0, iters=800, lr=0.01):
    """Ridge-regularised logistic fit of the three weights (market logit is a fixed offset)."""
    rows = _resolved(c); n = len(rows)
    if n < 30:
        return None
    w = dict(PRIOR); keys = ["w_ai", "w_xv", "w_flow"]; xs = ["x_ai", "x_xv", "x_flow"]
    for _ in range(iters):
        g = {k: lam * (w[k] - PRIOR[k]) for k in keys}
        for r in rows:
            z = logit(r["mid"]) + sum(w[k] * r[x] for k, x in zip(keys, xs))
            e = sigmoid(z) - r["outcome"]
            for k, x in zip(keys, xs):
                g[k] += e * r[x]
        for k in keys:
            w[k] -= lr * g[k] / max(1, n) * 10
    c.execute("INSERT INTO weights VALUES(?,?,?,?,?)", (time.time(), w["w_ai"], w["w_xv"], w["w_flow"], n))
    c.commit(); return w


def evaluate(c, bootstraps=2000, seed=7):
    """Does the combined strategy beat the market, and is its paper PnL distinguishable from luck?"""
    rows = _resolved(c); n = len(rows)
    if not n:
        return {"n": 0, "ready_for_real_money": False}
    mk = sum((r["mid"] - r["outcome"]) ** 2 for r in rows) / n
    ai = sum((r["p_ai"] - r["outcome"]) ** 2 for r in rows) / n
    cb = sum((r["p_comb"] - r["outcome"]) ** 2 for r in rows) / n
    pnl = []
    for r in rows:
        if r["side"] == "yes":
            pnl.append((1 if r["outcome"] else 0) - r["ask"] - friction(r["ask"]))
        elif r["side"] == "no":
            pnl.append((0 if r["outcome"] else 1) - (1 - r["bid"]) - friction(1 - r["bid"]))
    lo = None
    if len(pnl) >= 10:
        rnd = random.Random(seed)
        means = sorted(sum(rnd.choices(pnl, k=len(pnl))) / len(pnl) for _ in range(bootstraps))
        lo = means[int(0.05 * bootstraps)]                       # 5th percentile of mean PnL
    ready = (n >= 200 and len(pnl) >= 100 and cb < mk and lo is not None and lo > 0)
    return {"n": n, "brier_market": mk, "brier_ai": ai, "brier_combined": cb, "trades": len(pnl),
            "mean_pnl_per_contract": (sum(pnl) / len(pnl)) if pnl else None, "pnl_5th_pct": lo,
            "weights": current_weights(c), "ready_for_real_money": ready,
            "gate": "needs >=200 resolved, >=100 trades, beat market Brier, and 5th-pct PnL > 0"}
