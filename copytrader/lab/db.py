import sqlite3, time

SCHEMA = """
CREATE TABLE IF NOT EXISTS markets(
  venue TEXT, market_id TEXT, question TEXT, outcome_name TEXT, rules TEXT, close_time TEXT,
  first_seen REAL, resolved INTEGER DEFAULT 0, outcome INTEGER, resolved_ts REAL, event_ticker TEXT, slug TEXT,
  PRIMARY KEY(venue, market_id));
CREATE TABLE IF NOT EXISTS snapshots(
  ts REAL, venue TEXT, market_id TEXT, bid REAL, ask REAL, last REAL, volume REAL);
CREATE INDEX IF NOT EXISTS snap_m ON snapshots(venue, market_id, ts);
CREATE TABLE IF NOT EXISTS wallet_trades(
  id TEXT PRIMARY KEY, ts INTEGER, wallet TEXT, side TEXT, outcome TEXT, price REAL, usdc REAL,
  title TEXT, slug TEXT, condition_id TEXT);
CREATE TABLE IF NOT EXISTS forecasts(
  ts REAL, venue TEXT, market_id TEXT, model TEXT, p REAL, confidence TEXT, reasoning TEXT,
  sources TEXT, mid_at_forecast REAL, ask_at_forecast REAL, bid_at_forecast REAL,
  input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL);
CREATE TABLE IF NOT EXISTS pairs(poly_id TEXT, kalshi_id TEXT, score REAL, PRIMARY KEY(poly_id, kalshi_id));
CREATE TABLE IF NOT EXISTS features(
  ts REAL, day TEXT, venue TEXT, market_id TEXT, mid REAL, bid REAL, ask REAL,
  p_ai REAL, x_ai REAL, x_xv REAL, x_flow REAL, p_comb REAL, side TEXT, edge REAL, kelly REAL,
  PRIMARY KEY(venue, market_id, day));
CREATE TABLE IF NOT EXISTS weights(ts REAL, w_ai REAL, w_xv REAL, w_flow REAL, n INTEGER);
"""


def connect(path="lab.db"):
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    c.executescript(SCHEMA)
    for col in ("event_ticker TEXT", "slug TEXT"):        # migrate older DBs
        try:
            c.execute(f"ALTER TABLE markets ADD COLUMN {col}")
        except sqlite3.OperationalError:
            pass
    return c


def upsert_market(c, venue, mid, question, outcome_name, rules, close_time, event_ticker=None, slug=None):
    c.execute("""INSERT INTO markets(venue,market_id,question,outcome_name,rules,close_time,first_seen,event_ticker,slug)
                 VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(venue,market_id) DO UPDATE SET
                 question=excluded.question, rules=excluded.rules, close_time=excluded.close_time""",
              (venue, mid, question, outcome_name, rules, close_time, time.time(), event_ticker, slug))


def add_snapshot(c, venue, mid, bid, ask, last, volume, ts=None):
    c.execute("INSERT INTO snapshots VALUES(?,?,?,?,?,?,?)",
              (ts or time.time(), venue, mid, bid, ask, last, volume))


def latest_quote(c, venue, mid):
    r = c.execute("SELECT bid,ask,last FROM snapshots WHERE venue=? AND market_id=? ORDER BY ts DESC LIMIT 1",
                  (venue, mid)).fetchone()
    return dict(r) if r else None


def mid_of(q):
    if not q:
        return None
    if q["bid"] is not None and q["ask"] is not None and q["ask"] > 0:
        return (q["bid"] + q["ask"]) / 2
    return q["last"]
