"""Find the same event on both venues so each venue's price can inform the other."""
from copytrader.mapping import Mapper
from copytrader.sports import SportsMapper
from . import db


def build_pairs(c, kalshi_client):
    """Populate `pairs` from tracked Polymarket markets. Conservative: unmatched -> no pair."""
    k_rows = c.execute("SELECT * FROM markets WHERE venue='kalshi' AND resolved=0").fetchall()
    k_as_dicts = [{"ticker": r["market_id"], "title": r["question"], "yes_sub_title": "",
                   "close_time": r["close_time"]} for r in k_rows]
    yn = Mapper(k_as_dicts, min_score=0.8)
    sports = SportsMapper(kalshi_client.series_markets)
    n = 0
    for p in c.execute("SELECT * FROM markets WHERE venue='polymarket' AND resolved=0"):
        mk = None
        if (p["outcome_name"] or "").lower() == "yes":
            mk, score = yn.match(p["question"], p["market_id"], p["close_time"])
            mk = mk and mk["ticker"]
        elif p["slug"]:
            m, score, _ = sports.match(p["question"], p["slug"], p["outcome_name"])
            mk = m and m["ticker"]
        if mk:
            c.execute("INSERT OR REPLACE INTO pairs VALUES(?,?,?)", (p["market_id"], mk, score)); n += 1
    c.commit()
    return n


def other_side(c, venue, market_id):
    """(other_venue, other_market_id) or None."""
    if venue == "polymarket":
        r = c.execute("SELECT kalshi_id FROM pairs WHERE poly_id=?", (market_id,)).fetchone()
        return ("kalshi", r[0]) if r else None
    r = c.execute("SELECT poly_id FROM pairs WHERE kalshi_id=?", (market_id,)).fetchone()
    return ("polymarket", r[0]) if r else None
