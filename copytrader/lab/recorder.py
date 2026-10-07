"""Continuously snapshot both venues + tracked-wallet fills; settle resolved markets."""
import json, time
from datetime import datetime, timezone, timedelta
from . import db


def _f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _dt(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def record_kalshi(c, kalshi, horizon_days=7, now=None, min_volume=50, max_spread=0.10):
    """Snapshot open, non-parlay Kalshi markets closing within the horizon."""
    now = now or datetime.now(timezone.utc)
    n = 0
    for m in kalshi.open_markets(max_pages=10, exclude_parlays=True,
                                 max_close_ts=(now + timedelta(days=horizon_days)).timestamp()):
        if m.get("mve_collection_ticker") or m["ticker"].startswith("KXMVE"):
            continue                                   # skip multi-leg parlay contracts
        ct = _dt(m.get("close_time", ""))
        if not ct or ct > now + timedelta(days=horizon_days):
            continue
        bid, ask = _f(m.get("yes_bid_dollars")), _f(m.get("yes_ask_dollars"))
        if bid is None or ask is None or ask - bid > max_spread or (_f(m.get("volume_fp")) or 0) < min_volume:
            continue                                   # illiquid: not worth tracking or forecasting
        rules = " ".join(filter(None, [m.get("rules_primary"), m.get("rules_secondary")]))
        q = m.get("title") or ""
        sub = m.get("yes_sub_title") or ""
        db.upsert_market(c, "kalshi", m["ticker"], f"{q} [{sub}]" if sub and sub not in q else q,
                         "YES", rules, m.get("close_time"), m.get("event_ticker"))
        db.add_snapshot(c, "kalshi", m["ticker"], bid, ask,
                        _f(m.get("last_price_dollars")), _f(m.get("volume_fp")))
        n += 1
    c.commit()
    return n


def record_polymarket(c, session, pages=3):
    n = 0
    for p in range(pages):
        r = session.get("https://gamma-api.polymarket.com/markets", timeout=20, params={
            "closed": "false", "active": "true", "limit": 100, "offset": p * 100,
            "order": "volume24hr", "ascending": "false"})
        r.raise_for_status()
        for m in r.json():
            try:
                outs, prices = json.loads(m["outcomes"]), json.loads(m["outcomePrices"])
            except Exception:
                continue
            if len(outs) != 2:
                continue
            db.upsert_market(c, "polymarket", m["conditionId"], m["question"], outs[0],
                             m.get("description", ""), m.get("endDate"), None, m.get("slug"))
            db.add_snapshot(c, "polymarket", m["conditionId"], _f(m.get("bestBid")), _f(m.get("bestAsk")),
                            _f(prices[0]), _f(m.get("volume")))
            n += 1
    c.commit()
    return n


def record_wallets(c, poly, top_n=20, period="WEEK"):
    n = 0
    for t in poly.top_traders(top_n, period):
        time.sleep(0.4)                                # pace requests across wallets
        try:
            trades = poly.recent_trades(t["wallet"], 100)
        except Exception as e:
            print("wallet fetch failed:", t["wallet"][:10], repr(e)[:80]); continue
        for tr in trades:
            cur = c.execute("INSERT OR IGNORE INTO wallet_trades VALUES(?,?,?,?,?,?,?,?,?,?)",
                            (tr["id"], tr["ts"], tr["wallet"], tr["side"], tr["outcome"], tr["price"],
                             tr["usdc"], tr["title"], tr["slug"], tr["condition_id"]))
            n += cur.rowcount
    c.commit()
    return n


def settle(c, kalshi, session):
    """Mark known markets resolved using venue results."""
    n = 0
    open_k = {r["market_id"] for r in c.execute(
        "SELECT market_id FROM markets WHERE venue='kalshi' AND resolved=0")}
    if open_k:
        d = kalshi._req("GET", "/markets", params={"status": "settled", "limit": 1000})
        for m in d.get("markets", []):
            if m["ticker"] in open_k and m.get("result") in ("yes", "no"):
                c.execute("UPDATE markets SET resolved=1, outcome=?, resolved_ts=? WHERE venue='kalshi' AND market_id=?",
                          (1 if m["result"] == "yes" else 0, time.time(), m["ticker"])); n += 1
    open_p = {r["market_id"] for r in c.execute(
        "SELECT market_id FROM markets WHERE venue='polymarket' AND resolved=0")}
    if open_p:
        r = session.get("https://gamma-api.polymarket.com/markets", timeout=20, params={
            "closed": "true", "limit": 500, "order": "endDate", "ascending": "false"})
        r.raise_for_status()
        for m in r.json():
            if m.get("conditionId") in open_p:
                try:
                    prices = [float(x) for x in json.loads(m["outcomePrices"])]
                except Exception:
                    continue
                if prices and max(prices) >= 0.99:      # clean resolution only
                    c.execute("UPDATE markets SET resolved=1, outcome=?, resolved_ts=? WHERE venue='polymarket' AND market_id=?",
                              (1 if prices[0] >= 0.99 else 0, time.time(), m["conditionId"])); n += 1
    c.commit()
    return n
