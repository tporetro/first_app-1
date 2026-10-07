"""Sports moneyline mapper: Polymarket 'A vs. B' (outcome = team) -> Kalshi 'Team wins' YES.

Keyed on league + game date + BOTH teams, so a wrong-game match is very unlikely.
Anything not provably the same moneyline game is skipped and logged.
"""
import json, os, re, time
from datetime import date, datetime, timedelta
from .teams import norm, pro_team, label_team, PRO

# polymarket slug prefix -> (kalshi series, pro-league key or None for college/name-equality)
LEAGUES = {
    "nfl": ("KXNFLGAME", "nfl"), "nba": ("KXNBAGAME", "nba"),
    "mlb": ("KXMLBGAME", "mlb"), "nhl": ("KXNHLGAME", "nhl"),
    "cfb": ("KXNCAAFGAME", None), "cbb": ("KXNCAAMBGAME", None), "ncaab": ("KXNCAAMBGAME", None),
}
NON_MONEYLINE = re.compile(r"spread|o/u|total|over|under|handicap|both teams|:|\bmvp\b|prop", re.I)
VS = re.compile(r"^(.+?)\s+vs\.?\s+(.+)$", re.I)
EVENT_DATE = re.compile(r"-(\d{2})([A-Z]{3})(\d{2})")
MONTHS = {m: i + 1 for i, m in enumerate("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC".split())}


def parse_slug(slug: str):
    prefix = slug.split("-")[0].lower() if slug else ""
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})$", slug or "")
    d = date(int(m[1]), int(m[2]), int(m[3])) if m else None
    return prefix, d


def event_date(event_ticker: str):
    m = EVENT_DATE.search(event_ticker or "")
    if not m or m[2] not in MONTHS:
        return None
    return date(2000 + int(m[1]), MONTHS[m[2]], int(m[3]))


class SportsMapper:
    def __init__(self, series_loader, aliases_path=None, ttl_s=600, date_slack_days=1):
        self.load_series = series_loader      # series_ticker -> list of Kalshi market dicts
        self.ttl, self.slack = ttl_s, date_slack_days
        self.cache = {}
        self.aliases = json.load(open(aliases_path)) if aliases_path and os.path.exists(aliases_path) else {}

    def _events(self, series):
        ts, ev = self.cache.get(series, (0, None))
        if ev is None or time.time() - ts > self.ttl:
            ev = {}
            for m in self.load_series(series):
                ev.setdefault(m["event_ticker"], []).append(m)
            self.cache[series] = (time.time(), ev)
        return ev

    @staticmethod
    def _same_name(league_key, x, y):
        if norm(x) == norm(y):
            return True
        if league_key:
            tx, ty = pro_team(league_key, x), pro_team(league_key, y)
            return tx is not None and tx is ty
        return False

    def _same_team(self, league_key, prefix, poly_name, label):
        a = self.aliases.get(prefix, {}).get(norm(poly_name))
        if a is not None:
            return norm(label) == norm(a)
        if league_key:                                   # pro: identity via team table
            pt = pro_team(league_key, poly_name)
            return bool(pt) and any(t is pt for t in label_team(league_key, label))
        return norm(poly_name) == norm(label)            # college: exact normalized name

    def match(self, title, slug, outcome):
        """Return (kalshi_market, score, reason). market None => reason says why."""
        prefix, gdate = parse_slug(slug)
        if prefix not in LEAGUES:
            return None, 0.0, f"league '{prefix}' not supported"
        if NON_MONEYLINE.search(title or ""):
            return None, 0.0, "not a plain moneyline market"
        m = VS.match(title or "")
        if not m:
            return None, 0.0, "title not 'A vs. B'"
        a, b = m[1].strip(), m[2].strip()
        if not gdate:
            return None, 0.0, "no game date in slug"
        series, league_key = LEAGUES[prefix]
        if not any(self._same_name(league_key, outcome, x) for x in (a, b)):
            return None, 0.0, "outcome is not one of the two teams"
        for ev_ticker, mkts in self._events(series).items():
            ed = event_date(ev_ticker)
            if not ed or abs((ed - gdate).days) > self.slack or len(mkts) != 2:
                continue
            labels = [x["yes_sub_title"] for x in mkts]
            ok_ab = self._same_team(league_key, prefix, a, labels[0]) and self._same_team(league_key, prefix, b, labels[1])
            ok_ba = self._same_team(league_key, prefix, a, labels[1]) and self._same_team(league_key, prefix, b, labels[0])
            if not (ok_ab or ok_ba):
                continue
            for mk in mkts:                              # YES on the market for the team they bought
                if self._same_team(league_key, prefix, outcome, mk["yes_sub_title"]):
                    return mk, 1.0, "ok"
        return None, 0.0, "no Kalshi game with both teams on that date (add to sports_aliases.json?)"


def coverage_report(series_loader, leagues=("nfl", "nba", "mlb", "nhl")):
    """Kalshi labels not resolvable to a known pro team (extend teams.py / aliases)."""
    out = {}
    for lg in leagues:
        series, key = LEAGUES[lg]
        labels = {m["yes_sub_title"] for m in series_loader(series)}
        bad = sorted(l for l in labels if len(label_team(key, l)) != 1)
        out[lg] = {"labels": len(labels), "unresolved": bad}
    return out
