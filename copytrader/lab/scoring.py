"""Grade forecasts on resolved markets: does the AI beat the market price?"""
import math
from . import db

FEE = 0.02    # rough per-contract friction (fees + spread slippage), in $ per $1 contract


def brier(p, o): return (p - o) ** 2
def logloss(p, o):
    p = min(0.999, max(0.001, p)); return -(o * math.log(p) + (1 - o) * math.log(1 - p))


def paper_trade(f, outcome, edge_min=0.05):
    """Buy YES at ask if AI >> mid, else NO at (1-bid) if AI << mid. Returns pnl per contract or None."""
    mid, ask, bid = f["mid_at_forecast"], f["ask_at_forecast"], f["bid_at_forecast"]
    if mid is None:
        return None
    if f["p"] - mid >= edge_min:
        cost = ask if ask else mid
        return (1.0 if outcome else 0.0) - cost - FEE
    if mid - f["p"] >= edge_min:
        cost = (1 - bid) if bid else (1 - mid)
        return (0.0 if outcome else 1.0) - cost - FEE
    return None


def score(c, edge_min=0.05):
    rows = c.execute("""SELECT f.*, m.outcome FROM forecasts f JOIN markets m
                        ON m.venue=f.venue AND m.market_id=f.market_id
                        WHERE m.resolved=1 AND f.mid_at_forecast IS NOT NULL""").fetchall()
    n = len(rows)
    if not n:
        return {"n": 0}
    ai_b = sum(brier(r["p"], r["outcome"]) for r in rows) / n
    mk_b = sum(brier(r["mid_at_forecast"], r["outcome"]) for r in rows) / n
    pnls = [x for x in (paper_trade(r, r["outcome"], edge_min) for r in rows) if x is not None]
    bins = {}
    for r in rows:
        b = min(9, int(r["p"] * 10)); bins.setdefault(b, []).append(r["outcome"])
    cost = sum(r["cost_usd"] for r in rows)
    return {"n": n, "brier_ai": ai_b, "brier_market": mk_b, "ai_beats_market": ai_b < mk_b,
            "ai_logloss": sum(logloss(r["p"], r["outcome"]) for r in rows) / n,
            "mkt_logloss": sum(logloss(r["mid_at_forecast"], r["outcome"]) for r in rows) / n,
            "paper_trades": len(pnls), "paper_pnl_per_contract": (sum(pnls) / len(pnls)) if pnls else None,
            "paper_total": sum(pnls), "api_cost_usd": cost,
            "calibration": {f"{b*10}-{b*10+10}%": (len(v), sum(v) / len(v)) for b, v in sorted(bins.items())}}
