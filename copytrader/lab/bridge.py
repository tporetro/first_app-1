"""Order-routing bridge: combined-strategy decisions -> Kalshi orders, behind layered locks.

An order is sent ONLY if every lock is open:
  1. EVIDENCE GATE  strategy.evaluate()["ready_for_real_money"] is true   (no override on prod)
  2. --live flag AND env KALSHI_LIVE_CONFIRM=YES_SEND_REAL_ORDERS
  3. Kalshi API credentials present
  4. production host additionally needs env KALSHI_PROD_CONFIRM=I_ACCEPT_REAL_MONEY_RISK
  5. no KILL file, and the drawdown circuit-breaker is not tripped
  6. per-trade / per-market / daily USD caps, fresh-price edge re-check, one order per market per day
Anything else is a dry run: the plan is logged to the hash-chained ledger, nothing is sent.
`demo_skip_gate=True` bypasses ONLY lock 1 and ONLY on Kalshi's demo (fake-money) host, for testing.
"""
import json, math, os, time
from datetime import datetime, timezone
from copytrader.config import LIVE_CONFIRM_TOKEN
from copytrader.kalshi import _cents
from copytrader.ledger import Ledger
from . import strategy

PROD_CONFIRM = "I_ACCEPT_REAL_MONEY_RISK"
KILL_FILE = os.getenv("KILL_FILE", "KILL")
LIMITS = {"max_trade_usd": 25.0, "max_daily_usd": 100.0, "max_per_market_usd": 40.0,
          "max_signal_age_s": 6 * 3600, "breaker_drawdown_frac": 0.05}


def is_demo(base_url): return "demo-api" in base_url
def _today(now): return datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")


def realized_pnl_7d(c, now):
    """Sum PnL (USD) of our resolved orders in the last 7 days."""
    tot = 0.0
    for o in c.execute("""SELECT o.side,o.count,o.price,m.outcome FROM orders o JOIN markets m
                          ON m.venue=o.venue AND m.market_id=o.market_id
                          WHERE m.resolved=1 AND o.live=1 AND o.ts>?""", (now - 7 * 86400,)):
        won = (o["outcome"] == 1) if o["side"] == "yes" else (o["outcome"] == 0)
        tot += o["count"] * ((1.0 if won else 0.0) - o["price"])
    return tot


def lock_status(c, kalshi, base_url, live, demo_skip_gate, bankroll, now):
    """Return (live_allowed, reasons_blocked)."""
    why = []
    ev = strategy.evaluate(c)
    gate_open = ev.get("ready_for_real_money") or (demo_skip_gate and is_demo(base_url))
    if not gate_open:
        why.append("evidence gate closed (strategy.evaluate not ready_for_real_money)")
    if not live:
        why.append("--live not passed")
    if os.getenv("KALSHI_LIVE_CONFIRM") != LIVE_CONFIRM_TOKEN:
        why.append("KALSHI_LIVE_CONFIRM not set")
    if not kalshi.authed:
        why.append("no Kalshi credentials")
    if not is_demo(base_url) and os.getenv("KALSHI_PROD_CONFIRM") != PROD_CONFIRM:
        why.append("production host needs KALSHI_PROD_CONFIRM")
    if os.path.exists(KILL_FILE):
        why.append(f"kill switch file '{KILL_FILE}' present")
    if realized_pnl_7d(c, now) < -LIMITS["breaker_drawdown_frac"] * bankroll:
        why.append("drawdown circuit-breaker tripped (7d loss > 5% of bankroll)")
    return (not why), why


def route(c, kalshi, base_url, ledger, live=False, demo_skip_gate=False, limits=None, now=None):
    now = now or time.time(); L = {**LIMITS, **(limits or {})}; day = _today(now)
    bankroll = kalshi.buying_power_usd() if kalshi.authed else 1000.0
    allowed, blocked = lock_status(c, kalshi, base_url, live, demo_skip_gate, bankroll, now)
    ledger.append("route_start", {"live_allowed": allowed, "blocked_by": blocked, "bankroll": bankroll})
    spent_today = c.execute("SELECT COALESCE(SUM(usd),0) FROM orders WHERE day=? AND live=1", (day,)).fetchone()[0]
    sent = planned = 0
    rows = c.execute("""SELECT f.* FROM features f JOIN markets m ON m.venue=f.venue AND m.market_id=f.market_id
                        WHERE f.day=? AND f.side IS NOT NULL AND f.venue='kalshi' AND m.resolved=0
                        ORDER BY f.edge DESC""", (day,)).fetchall()
    for f in rows:
        def skip(r): ledger.append("route_skip", {"market": f["market_id"], "reason": r})
        if now - f["ts"] > L["max_signal_age_s"]:
            skip("decision stale"); continue
        if c.execute("SELECT 1 FROM orders WHERE venue='kalshi' AND market_id=? AND day=?", (f["market_id"], day)).fetchone():
            skip("already ordered today"); continue
        try:
            mk = kalshi.market(f["market_id"])
        except Exception as e:
            skip(f"quote fetch failed {repr(e)[:60]}"); continue
        if mk.get("status") not in ("open", "active"):
            skip(f"market status {mk.get('status')}"); continue
        ask = _cents(mk, f"{f['side']}_ask")                          # fresh price we would pay (cents)
        if ask is None or not (1 <= ask <= 99):
            skip("no fresh ask"); continue
        price = ask / 100.0
        p_side = f["p_comb"] if f["side"] == "yes" else 1 - f["p_comb"]
        edge = p_side - price - strategy.friction(price)
        if edge <= strategy.MIN_EDGE:
            skip(f"edge gone at fresh price ({edge:.3f})"); continue
        usd = min(f["kelly"] * bankroll, L["max_trade_usd"], L["max_daily_usd"] - spent_today, L["max_per_market_usd"])
        n = math.floor(usd / price) if usd > 0 else 0
        if n < 1:
            skip("size below one contract or daily cap reached"); continue
        cost = n * price
        plan = {"market": f["market_id"], "side": f["side"], "count": n, "limit_cents": ask,
                "usd": round(cost, 2), "edge": round(edge, 4), "p_comb": round(f["p_comb"], 4)}
        if not allowed:
            ledger.append("route_planned_blocked", plan); planned += 1; continue
        resp = kalshi.place_limit_buy(f["market_id"], f["side"], n, ask, live=True)
        c.execute("INSERT INTO orders VALUES(?,?,?,?,?,?,?,?,?,?,?)", (now, day, "kalshi", f["market_id"], f["side"],
                  n, price, cost, 1, f["p_comb"], json.dumps(resp, default=str)[:2000]))
        c.commit(); spent_today += cost; sent += 1
        ledger.append("route_order_sent", {**plan, "response": resp})
    ledger.append("route_end", {"sent": sent, "planned_blocked": planned})
    return {"sent": sent, "planned_blocked": planned, "blocked_by": blocked}
