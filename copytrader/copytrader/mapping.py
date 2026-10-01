"""Semantic correlation layer: Polymarket market -> equivalent Kalshi market + side.

Pipeline for each leader fill:

1. **Macro gate** -- only election/politics/finance/economics markets pass. Sports,
   esports, short-dated crypto up/down etc. are dropped.
2. **Manual overrides** -- ``mapping_overrides.json`` pins a Polymarket condition id
   or slug to a Kalshi ticker. Always preferred over the model.
3. **Semantic retrieval** -- TF-IDF cosine over a normalised vocabulary (synonyms,
   light stemming) against every open Kalshi market in the configured categories,
   blended with named-entity recall.
4. **Hard consistency checks** -- years and numeric thresholds in the Polymarket
   question must appear in the Kalshi contract; named outcomes must appear in the
   Kalshi market; negation must agree. Violations are heavy penalties.
5. **Ambiguity guard** -- the winner must clear ``min_score`` and beat the runner-up
   by ``min_margin``; otherwise no trade.

A final price-divergence check happens in the router with live quotes: if Kalshi's
price for the mapped side is far from the leader's fill price the pair is treated
as a mismap (or stale) and skipped.
"""
from __future__ import annotations

import json
import logging
import math
import os
import re
import threading
import time
from collections import Counter, defaultdict
from typing import Optional

from .config import MappingConfig
from .models import KalshiCandidate, LeaderTrade, MarketMatch

log = logging.getLogger(__name__)

# ---------------------------------------------------------------- vocabulary

# Each domain: the words that put a Polymarket question in it, and the Kalshi categories
# to search for its twin. Enable/disable domains in config ("mapping.domains").
DOMAINS = {
    "politics": {
        "kalshi": ["Elections", "Politics"],
        "keywords": {
            "election", "elections", "elected", "president", "presidential", "presidency", "senate",
            "senator", "house", "congress", "congressional", "governor", "gubernatorial", "mayor",
            "mayoral", "primary", "primaries", "caucus", "nominee", "nomination", "parliament",
            "parliamentary", "prime minister", "chancellor", "referendum", "vote", "votes", "ballot",
            "electoral", "democrat", "democrats", "democratic", "republican", "republicans", "gop",
            "speaker", "impeach", "impeached", "cabinet", "supreme court", "midterm", "midterms",
            "popular vote", "swing state", "approval rating", "secretary", "white house", "pope",
            "coalition", "labour", "conservative", "tory", "shutdown", "executive order",
            "minister-president", "trump", "vance", "newsom", "pardon", "indicted", "resign",
        },
    },
    "geopolitics": {
        "kalshi": ["World", "Politics"],
        "keywords": {
            "war", "ceasefire", "cease-fire", "invade", "invasion", "airstrike", "airstrikes",
            "military", "troops", "missile", "missiles", "nuclear", "blockade", "sanctions",
            "treaty", "peace deal", "peace talks", "annex", "coup", "regime", "embassy", "nato",
            "ukraine", "russia", "putin", "zelensky", "israel", "netanyahu", "gaza", "hamas",
            "hezbollah", "iran", "khamenei", "china", "xi jinping", "taiwan", "north korea",
            "kim jong", "venezuela", "maduro", "syria", "houthi", "houthis", "un security council",
            "summit", "hostage", "hostages", "strait of hormuz", "greenland", "panama canal",
        },
    },
    "economics": {
        "kalshi": ["Economics", "Financials", "Commodities", "Companies"],
        "keywords": {
            "fed", "fomc", "federal reserve", "interest rate", "interest rates", "rate cut",
            "rate cuts", "rate hike", "bps", "basis points", "cpi", "inflation", "pce", "gdp",
            "unemployment", "jobless", "payrolls", "nonfarm", "jobs report", "recession", "s&p",
            "s&p 500", "nasdaq", "dow", "treasury", "yield", "yields", "tariff", "tariffs",
            "debt ceiling", "ecb", "boe", "bank of england", "bank of japan", "boj", "powell",
            "stock market", "oil price", "crude oil", "wti", "brent", "gas prices", "gold",
            "silver", "mortgage", "housing", "trade deal", "deficit", "budget", "tax", "irs",
            "earnings", "ipo", "market cap", "largest company",
        },
    },
    "crypto": {
        "kalshi": ["Crypto"],
        "keywords": {"bitcoin", "btc", "ethereum", "eth", "solana", "xrp", "dogecoin", "crypto"},
    },
    "weather": {
        "kalshi": ["Climate and Weather"],
        "keywords": {"temperature", "highest temperature", "rain", "snow", "hurricane",
                     "tornado", "heatwave", "weather", "precipitation"},
    },
}
DEFAULT_DOMAINS = ["politics", "geopolitics", "economics", "weather"]
EXCLUDE_KEYWORDS = {
    "up or down", "updown", "nfl", "nba", "mlb", "nhl", "epl", "ufc", "fifa", "uefa",
    "premier league", "la liga", "serie a", "bundesliga", "champions league", "world cup",
    "tennis", "atp", "wta", "golf", "pga", "f1", "grand prix", "esports", "lol",
    "counter-strike", "cs2", "dota", "valorant", "ncaa", "cricket", "boxing", "mma",
    "fc", "touchdown", "super bowl", "stanley cup",
    # short-dated crypto candles: by the time we mirror, the window is gone
    "5m", "15m", "1h", "4h", "hourly", "5 minutes", "15 minutes",
}

SYNONYMS = [
    (r"\bfederal reserve\b|\bfomc\b|\bthe fed\b", " fed "),
    (r"\bunited states\b|\bu\.s\.a?\b|\busa\b", " us "),
    (r"\bunited kingdom\b|\bu\.k\.\b|\bbritain\b|\bgreat britain\b", " uk "),
    (r"\bbasis points?\b|\bbps\b|\bbp\b", " bp "),
    (r"\bdecreases?\b|\blowers?\b|\bcuts?\b|\bcutting\b", " cut "),
    (r"\bincreases?\b|\braises?\b|\bhikes?\b|\bhiking\b", " hike "),
    (r"\bdemocrats?\b|\bdemocratic\b|\bdems?\b", " democrat "),
    (r"\brepublicans?\b|\bgop\b", " republican "),
    (r"\bpresidential\b|\bpresidency\b", " president "),
    (r"\bgubernatorial\b", " governor "),
    (r"\bmayoral\b", " mayor "),
    (r"\bs&p\s*500\b|\bs&p\b|\bspx\b", " sp500 "),
    (r"\bnasdaq\s*100\b|\bndx\b", " nasdaq "),
    (r"\bconsumer price index\b", " cpi "),
    (r"\bnon-?farm payrolls?\b|\bjobs report\b", " payrolls "),
    (r"\bunemployment rate\b", " unemployment "),
    (r"\bnew york city\b|\bnyc\b", " nyc "),
    (r"\bpercent\b|%", " pct "),
    (r"\bwins?\b|\bwinning\b|\bwinner\b|\bvictory\b", " win "),
]
STOPWORDS = set(
    "a an the of in on at to for by with will be is are was were be been being it its "
    "this that these those or and as from than then before after during between into "
    "over under up down above below any each which who whom what when where how there "
    "their they he she his her him do does did not no yes market event question resolve "
    "resolves resolution according per".split()
)
NEGATIONS = {"not", "no", "fail", "fails", "without", "never", "lose", "loses", "lost"}
UNIT_SPLIT = re.compile(r"(\d)([a-z%])", re.I)
YEAR_RE = re.compile(r"\b(20[2-4]\d)\b")
DATE_RE = re.compile(
    r"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b|"
    r"\b(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\.?\s+\d{1,2}(?:st|nd|rd|th)?\b",
    re.I,
)
NUM_RE = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])")
CAP_RE = re.compile(r"\b([A-Z][a-zA-Z'\.\-]+(?:\s+[A-Z][a-zA-Z'\.\-]+)*)")
YES_NO = {"yes", "no"}
MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august",
          "september", "october", "november", "december"]
MONTH_RE = re.compile(r"\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\b\.?", re.I)
COMPARATORS = {
    "above": ["above", "over", "more than", "greater than", "at least", "exceed", "higher than", "or more", "or higher", "or above"],
    "below": ["below", "under", "less than", "fewer than", "lower than", "at most", "or less", "or lower", "or below"],
    "between": ["between"],
}
# multi-leg / parlay style Kalshi products never mirror a single Polymarket market
EXCLUDED_SERIES_MARKERS = ("COMBO", "PARLAY", "KXMV", "MULTI", "THREESTATE", "FOURSTATE",
                           "FIVESTATE", "SIXSTATE")
# scope qualifiers that change what a contract pays on; both sides must agree
QUALIFIERS = {
    "state_legislature": ["state senate", "state house", "state legislature", "state assembly"],
    "first_round": ["first round", "1st round"],
    "runoff": ["runoff", "run-off", "second round", "qualify", "advance to"],
    "primary": ["primary", "nomination", "nominee"],
    "margin": ["margin", "closest", "smallest margin", "largest margin"],
    "popular_vote_share": ["of the vote", "of the valid vote", "of the popular vote", "vote share"],
    "relative_order": ["next leader out", "next to leave", "first to leave", "next one out"],
    "temp_max": ["highest temperature", "maximum temperature", "high temperature"],
    "temp_min": ["lowest temperature", "minimum temperature", "low temperature"],
}
# what has to happen for the contract to pay; both sides must name the same kind of event
EVENT_TYPES = {
    "invasion": {"invade", "invades", "invaded", "invasion"},
    "arrest": {"arrest", "arrested", "arrests"},
    "pardon": {"pardon", "pardons", "pardoned"},
    "ceasefire": {"ceasefire"},
    "resignation": {"resign", "resigns", "resigned", "resignation"},
    "impeachment": {"impeach", "impeached", "impeachment"},
    "indictment": {"indict", "indicted", "indictment"},
    "strike": {"strike", "strikes", "airstrike", "airstrikes"},
    "visit": {"visit", "visits", "visited", "travel", "travels"},
    "military_action": {"military", "attack", "attacks"},
    "meeting": {"meet", "meets"},
}
REGION_RE = re.compile(r"\belection from ([A-Z][\w ]+?)\s*\??$")


def event_types(text: str) -> set[str]:
    words = set(re.findall(r"[a-z]+", text.lower()))
    return {k for k, ws in EVENT_TYPES.items() if words & ws}
ORDINALS = {"first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4,
            "fifth": 5, "5th": 5, "sixth": 6, "6th": 6}
RANK_RE = re.compile(
    r"\b(first|second|third|fourth|fifth|sixth|1st|2nd|3rd|4th|5th|6th)[\s-]+(?:most|place)\b|"
    r"\bfinish(?:es)?\s+(?:in\s+)?(first|second|third|fourth|fifth|sixth|1st|2nd|3rd|4th|5th|6th)\b",
    re.I,
)


def normalise(text: str) -> str:
    t = " " + UNIT_SPLIT.sub(r"\1 \2", text.lower()) + " "
    for pat, rep in SYNONYMS:
        t = re.sub(pat, rep, t)
    return t


def _stem(w: str) -> str:
    for suf in ("ing", "ers", "ies", "es", "ed", "s"):
        if len(w) > len(suf) + 3 and w.endswith(suf):
            return w[: -len(suf)] + ("y" if suf == "ies" else "")
    return w


def tokens(text: str) -> list[str]:
    out = []
    for w in re.findall(r"[a-z0-9][a-z0-9\.']*", normalise(text)):
        w = w.strip(".'")
        if not w or w in STOPWORDS:
            continue
        out.append(_stem(w))
    return out


def numbers(text: str) -> set[float]:
    """Numeric thresholds, excluding years and ordinal/date noise."""
    out = set()
    clean = YEAR_RE.sub(" ", DATE_RE.sub(" ", UNIT_SPLIT.sub(r"\1 \2", text.replace(",", ""))))
    clean = re.sub(r"[<>≥≤]", " ", clean)
    for m in NUM_RE.findall(clean):
        try:
            out.add(round(float(m), 4))
        except ValueError:
            pass
    return out


def years(text: str) -> set[str]:
    return set(YEAR_RE.findall(text))


def entities(text: str) -> set[str]:
    ents = set()
    for m in CAP_RE.findall(text):
        for w in m.split():
            w = w.strip(".'-").lower()
            if w and w not in STOPWORDS and len(w) > 2 and not MONTH_RE.fullmatch(w):
                ents.add(_stem(w))
    return ents


DAY_RE = re.compile(
    r"\b(january|february|march|april|may|june|july|august|september|october|november|december|"
    r"jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b", re.I)


def days(text: str) -> set[tuple[str, int]]:
    """Specific calendar days mentioned, e.g. {('oct', 1)}."""
    return {(m.group(1).lower()[:3], int(m.group(2))) for m in DAY_RE.finditer(text)}


TICKER_YEAR_RE = re.compile(r"^(?:(20[2-4]\d)|([2-4]\d))$")  # bare cycle years only, not dates like 26JUN30


def ticker_years(*tickers: str) -> set[str]:
    """Years encoded in Kalshi tickers, e.g. SENATEOHS-26-R -> {'2026'}, KXFED-26OCT -> {'2026'}."""
    out = set()
    for t in tickers:
        for seg in (t or "").upper().split("-")[1:]:
            m = TICKER_YEAR_RE.match(seg)
            if m:
                out.add(m.group(1) or f"20{m.group(2)}")
    return out


# "no change" / "unchanged" is a rate-hold outcome, not a negation of the question
HOLD_RE = re.compile(r"\bno (?:rate )?change\b|\bunchanged\b|\bleave rates? (?:steady|unchanged)\b", re.I)
HOLD_SYNONYMS = "maintain maintains hold rate"

DISTRICT_RE = re.compile(r"\b([A-Z]{2})-(\d{1,2}|AL)\b")
# Kalshi contracts that pay on an announcement are not the event itself (e.g. "announce an IPO" vs "IPO")
ANNOUNCE_WORDS = {"announce", "announces", "announced", "confirm", "confirms", "confirmed"}


def districts(text: str) -> set[str]:
    return {f"{s}{int(d):02d}" if d.isdigit() else f"{s}{d}" for s, d in DISTRICT_RE.findall(text)}


PARTIES = {
    "republican": {"republican", "republicans", "gop"},
    "democrat": {"democrat", "democrats", "democratic"},
}


def parties(text: str) -> set[str]:
    words = set(re.findall(r"[a-z]+", text.lower()))
    return {p for p, ws in PARTIES.items() if words & ws}


def _deadline_equivalent(q_days: set, k_days: set, title: str, khead: str) -> bool:
    """'by Oct 31' (end of day) pays the same as 'before Nov 1'."""
    if not re.search(r"\bby\b", title, re.I) or not re.search(r"\bbefore\b", khead, re.I):
        return False
    from datetime import date, timedelta
    q_years, k_years = years(title), years(khead)
    for mon, d in k_days:
        try:
            prev = date(2001, MONTHS.index(next(m for m in MONTHS if m.startswith(mon))) + 1, d) - timedelta(days=1)
        except (ValueError, StopIteration):
            continue
        if (MONTHS[prev.month - 1][:3], prev.day) not in q_days:
            continue
        # "before Jan 1, 2027" is "by Dec 31, 2026": the question's year must be the earlier one
        if (mon, d) == ("jan", 1):
            # crossing a year boundary: only trust it when the question states the year
            if not (q_years and k_years and ({str(int(y) - 1) for y in k_years} & q_years)):
                continue
        elif q_years and k_years and not (q_years & k_years):
            continue
        return True
    return False


def months(text: str, close_time: str = "") -> set[str]:
    out = {m.group(1).lower()[:3] for m in MONTH_RE.finditer(text)}
    if close_time[5:7].isdigit():
        out.add(MONTHS[int(close_time[5:7]) - 1][:3])
    return out


def comparators(text: str) -> set[str]:
    t = f" {text.lower()} "
    out = {k for k, words in COMPARATORS.items()
           if any(re.search(rf"(?<![a-z]){re.escape(w)}(?![a-z])", t) for w in words)}
    if re.search(r"\d\s*°?f?\s*(?:-|–|to)\s*\$?\d", t) and not re.search(r"\d{4}-\d{2}", t):
        out.add("between")
    if re.search(r"[>≥]\s*\$?\d", t):
        out.add("above")
    if re.search(r"[<≤]\s*\$?\d", t):
        out.add("below")
    return out


def qualifiers(text: str) -> set[str]:
    t = f" {text.lower()} "
    return {k for k, words in QUALIFIERS.items()
            if any(re.search(rf"(?<![a-z]){re.escape(w)}(?![a-z])", t) for w in words)}


def rank(text: str) -> int:
    """Finishing position a contract pays on; plain 'win' / 'most votes' is 1."""
    m = RANK_RE.search(text)
    if not m:
        return 1
    return ORDINALS[(m.group(1) or m.group(2)).lower()]


def classify(trade_title: str, slug: str = "", event_slug: str = "",
             domains: Optional[list] = None) -> tuple[Optional[str], str]:
    """Return (domain, reason) for an enabled domain, or (None, reason)."""
    hay = f" {trade_title} {slug.replace('-', ' ')} {event_slug.replace('-', ' ')} ".lower()
    for k in EXCLUDE_KEYWORDS:
        if re.search(rf"(?<![a-z0-9]){re.escape(k)}(?![a-z0-9])", hay):
            return None, f"excluded keyword '{k.strip()}'"
    for name in domains or DEFAULT_DOMAINS:
        for k in DOMAINS[name]["keywords"]:
            if re.search(rf"(?<![a-z]){re.escape(k)}(?![a-z])", hay):
                return name, f"{name} keyword '{k}'"
    return None, "no keyword from an enabled domain"


def is_macro(trade_title: str, slug: str = "", event_slug: str = "",
             domains: Optional[list] = None) -> tuple[bool, str]:
    dom, why = classify(trade_title, slug, event_slug, domains)
    return dom is not None, why


def kalshi_categories_for(domains: list) -> list:
    out = []
    for d in domains:
        out += [c for c in DOMAINS[d]["kalshi"] if c not in out]
    return out


# -------------------------------------------------------------------- index


class KalshiIndex:
    """TF-IDF index over open Kalshi markets."""

    def __init__(self, candidates: list[KalshiCandidate]):
        self.cands = candidates
        self.docs: list[Counter] = []
        self.df: Counter = Counter()
        self.inv: dict[str, set[int]] = defaultdict(set)
        self.full_text: list[str] = []
        for i, c in enumerate(candidates):
            text = f"{c.event_title} {c.title} {c.yes_sub_title}"
            tf = Counter(tokens(text))
            self.docs.append(tf)
            self.full_text.append(f"{text} {c.rules} {c.close_time}")
            for t in tf:
                self.df[t] += 1
                self.inv[t].add(i)
        self.n = max(1, len(candidates))
        self.siblings = Counter(c.event_ticker for c in candidates)
        self.norms = [self._norm(self._weights(tf)) for tf in self.docs]

    def idf(self, t: str) -> float:
        return math.log((1 + self.n) / (1 + self.df.get(t, 0))) + 1.0

    def _weights(self, tf: Counter) -> dict[str, float]:
        return {t: (1 + math.log(c)) * self.idf(t) for t, c in tf.items()}

    @staticmethod
    def _norm(w: dict) -> float:
        return math.sqrt(sum(v * v for v in w.values())) or 1.0

    def search(self, query: str, k: int = 10) -> list[tuple[int, float]]:
        qtf = Counter(tokens(query))
        qw = self._weights(qtf)
        qn = self._norm(qw)
        cand_ids: set[int] = set()
        for t in qw:
            cand_ids |= self.inv.get(t, set())
        scored = []
        for i in cand_ids:
            dw = self._weights(self.docs[i])
            dot = sum(qw[t] * dw.get(t, 0.0) for t in qw)
            scored.append((i, dot / (qn * self.norms[i])))
        scored.sort(key=lambda x: -x[1])
        return scored[:k]


# ------------------------------------------------------------------- mapper


class MarketMapper:
    def __init__(self, cfg: MappingConfig, kalshi_client=None, base_dir: str = "."):
        self.cfg = cfg
        self.kalshi = kalshi_client
        self.index: Optional[KalshiIndex] = None
        self._built = 0.0
        self._lock = threading.Lock()
        self._cache: dict[tuple, tuple[float, Optional[MarketMatch], list]] = {}
        self.overrides = {"condition_id": {}, "slug": {}}
        unknown = set(cfg.domains) - set(DOMAINS)
        if unknown:
            raise ValueError(f"Unknown mapping domains {sorted(unknown)}; choose from {sorted(DOMAINS)}")
        self.categories = cfg.kalshi_categories or kalshi_categories_for(cfg.domains)
        if cfg.overrides_path:
            p = cfg.overrides_path
            p = p if os.path.isabs(p) else os.path.join(base_dir, p)
            if os.path.exists(p):
                with open(p, "r", encoding="utf-8") as fh:
                    raw = json.load(fh)
                self.overrides["condition_id"] = {k.lower(): v for k, v in raw.get("condition_id", {}).items()}
                self.overrides["slug"] = raw.get("slug", {})
                log.info("Loaded %d mapping overrides", sum(len(v) for v in self.overrides.values()))

    # -- index lifecycle -------------------------------------------------
    def set_candidates(self, cands: list[KalshiCandidate]) -> None:
        with self._lock:
            self.index = KalshiIndex(cands)
            self._built = time.time()
            self._cache.clear()

    def refresh_index(self, force: bool = False) -> int:
        if self.kalshi is None:
            return 0
        if not force and self.index and time.time() - self._built < self.cfg.index_refresh_s:
            return len(self.index.cands)
        cands = self.kalshi.list_candidates(self.categories)
        self.set_candidates(cands)
        log.info("Kalshi index built: %d open markets in %s", len(cands), self.categories)
        return len(cands)

    # -- mapping ---------------------------------------------------------
    def map_trade(self, t: LeaderTrade) -> tuple[Optional[MarketMatch], list[str]]:
        return self.map(t.title, t.outcome, t.condition_id, t.slug, t.event_slug)

    def map(self, title: str, outcome: str, condition_id: str = "", slug: str = "",
            event_slug: str = "") -> tuple[Optional[MarketMatch], list[str]]:
        key = (condition_id or title, outcome)
        cached = self._cache.get(key)
        if cached and time.time() - cached[0] < self.cfg.index_refresh_s:
            return cached[1], cached[2]
        res = self._map_uncached(title, outcome, condition_id, slug, event_slug)
        self._cache[key] = (time.time(), *res)
        return res

    def _override(self, condition_id: str, slug: str, outcome: str) -> Optional[MarketMatch]:
        ov = self.overrides["condition_id"].get((condition_id or "").lower()) or self.overrides["slug"].get(slug)
        if not ov:
            return None
        oc = outcome.strip().lower()
        if "outcomes" in ov:  # explicit named-outcome mapping
            side = {k.lower(): v for k, v in ov["outcomes"].items()}.get(oc)
            if side not in ("yes", "no"):
                return None
        else:
            if oc not in YES_NO:
                return None
            side = oc
            if ov.get("invert"):
                side = "no" if side == "yes" else "yes"
        return MarketMatch(ov["ticker"], side, 1.0, "override", ov.get("note", ov["ticker"]),
                           reasons=["manual override"])

    def _map_uncached(self, title, outcome, condition_id, slug, event_slug):
        reasons: list[str] = []
        ov = self._override(condition_id, slug, outcome)
        if ov:
            return ov, ["manual override"]
        ok, why = is_macro(title, slug, event_slug, self.cfg.domains)
        reasons.append(why)
        if not ok:
            return None, reasons
        if not self.index or not self.index.cands:
            return None, reasons + ["kalshi index empty"]

        oc = outcome.strip()
        named = oc.lower() not in YES_NO and bool(oc)
        query = f"{title} {oc}" if named else title
        is_hold = bool(HOLD_RE.search(title))
        if is_hold:
            query = f"{query} {HOLD_SYNONYMS}"
        q_parties = parties(title)
        q_districts = districts(title)
        q_words = set(re.findall(r"[a-z]+", title.lower()))
        q_events = event_types(title)
        q_region = REGION_RE.search(title)
        hits = self.index.search(query, k=15)
        if not hits:
            return None, reasons + ["no lexical overlap with any Kalshi market"]

        q_years, q_nums = years(title), numbers(title)
        q_months, q_cmp = months(title), comparators(title)
        q_qual, q_rank = qualifiers(title), rank(title)
        q_days = days(title)
        domain, _ = classify(title, slug, event_slug, self.cfg.domains)
        strict = domain in ("weather", "crypto")  # location/asset must match exactly
        q_proper = {e for e in entities(title) if e[:3] not in {m[:3] for m in MONTHS}} - {"will"}
        q_ents = entities(title) | (entities(oc) if named else set())
        q_neg = bool(NEGATIONS & set(re.findall(r"[a-z']+", HOLD_RE.sub("hold", title).lower())))
        oc_toks = set(tokens(oc)) if named else set()

        scored, vetoed = [], []
        for i, cos in hits:
            c = self.index.cands[i]
            if any(mk in f"{c.series_ticker} {c.event_ticker}".upper() for mk in EXCLUDED_SERIES_MARKERS):
                continue
            ktext = self.index.full_text[i]
            khead = f"{c.event_title} {c.title} {c.yes_sub_title}"
            ktoks = set(tokens(ktext))
            notes, pen = [], 0.0
            k_ents = entities(f"{c.event_title} {c.title} {c.yes_sub_title}") | ktoks
            ent_recall = len(q_ents & k_ents) / len(q_ents) if q_ents else 0.5
            if len(q_ents) >= 2 and ent_recall < 0.75:
                pen += 0.15
                notes.append(f"entities missing from Kalshi market: {sorted(q_ents - k_ents)}")
            # Hard vetoes: differences that change what the contract pays on.
            veto = []
            if q_years:
                head_years = years(khead)
                # the title's year wins over rules boilerplate; else the ticker's year, else the rules
                k_years = head_years or ticker_years(c.event_ticker, c.ticker) or years(ktext)
                year_boundary_deadline = bool(q_days) and _deadline_equivalent(q_days, days(khead), title, khead)
                if not (q_years & k_years) and not year_boundary_deadline:
                    veto.append(f"year {sorted(q_years)} vs {sorted(k_years)}")
                elif q_years & head_years:
                    pen -= 0.05  # year stated in the contract title itself: small bonus
            k_cmp = comparators(khead)
            if q_cmp != k_cmp:
                veto.append(f"comparator {sorted(q_cmp)} vs {sorted(k_cmp)}")
            k_qual = qualifiers(khead)
            if q_qual != k_qual:
                veto.append(f"qualifier {sorted(q_qual)} vs {sorted(k_qual)}")
            k_rank = rank(khead)
            if q_rank != k_rank:
                veto.append(f"rank {q_rank} vs {k_rank}")
            deadline_eq = False
            if q_days:
                k_days = days(khead)
                deadline_eq = bool(k_days) and not (q_days & k_days) and _deadline_equivalent(q_days, k_days, title, khead)
                if k_days and not (q_days & k_days) and not deadline_eq:
                    veto.append(f"date {sorted(q_days)} vs {sorted(k_days)}")
            if q_districts:
                k_districts = districts(khead) | {seg for seg in c.ticker.upper().split("-")}
                if not (q_districts & k_districts):
                    veto.append(f"district {sorted(q_districts)} not in contract")
            k_words = set(re.findall(r"[a-z]+", khead.lower()))
            # judge by the payout rule, not the headline ("Will it be confirmed that..." is just phrasing)
            rule_head = c.rules[:240].lower()
            rule_words = set(re.findall(r"[a-z]+", rule_head))
            announce_only = bool(rule_words & ANNOUNCE_WORDS) and not re.search(r"\beither\b|\bor (?:has )?actually\b", rule_head)
            if announce_only and not (q_words & ANNOUNCE_WORDS):
                veto.append("contract pays on an announcement, question on the event")
            k_events = event_types(khead)
            if (q_events or k_events) and q_events != k_events:
                veto.append(f"event {sorted(q_events)} vs {sorted(k_events)}")
            hold_contract = is_hold and re.search(r"\b0\s*bps\b", khead.lower())
            if "bps" in k_words and not q_nums and not hold_contract:
                veto.append("contract specifies a move size the question does not")
            if q_region and not set(tokens(q_region.group(1))) <= set(tokens(khead)):
                veto.append(f"regional result '{q_region.group(1)}' vs contract")
            if ("final" in q_words) != ("final" in k_words):
                veto.append("'final' scope differs")
            if strict and q_proper - set(tokens(khead)) - entities(khead):
                veto.append(f"place/asset {sorted(q_proper - set(tokens(khead)) - entities(khead))} not in contract")
            if q_nums:
                k_nums = numbers(f"{c.title} {c.yes_sub_title} {c.event_title} {c.rules}")
                missing = [n for n in q_nums if not any(abs(n - kn) < 1e-6 for kn in k_nums)]
                if missing:
                    veto.append(f"threshold(s) {missing} not in contract")
            if veto:
                vetoed.append(f"{c.ticker} vetoed ({'; '.join(veto)})")
                continue
            # Soft penalties.
            if q_months and not deadline_eq and not (q_months & months(f"{khead} {c.rules}", c.close_time)):
                pen += 0.20
                notes.append(f"month mismatch {sorted(q_months)}")
            k_neg = bool(NEGATIONS & set(re.findall(r"[a-z']+", c.title.lower())))
            if k_neg != q_neg:
                pen += 0.20
                notes.append("negation mismatch")
            if self.index.siblings[c.event_ticker] > 1 and c.yes_sub_title:
                sub_toks = set(tokens(c.yes_sub_title)) - {"party", "yes"}
                party_market = bool(q_parties) and bool(q_parties & parties(f"{c.title} {c.event_title}"))
                if sub_toks and not (sub_toks & set(tokens(query))) and not party_market:
                    pen += 0.35
                    notes.append(f"sibling outcome '{c.yes_sub_title}' not named in question")
            side = "yes"
            if named:
                sub = set(tokens(f"{c.yes_sub_title} {c.title}"))
                if oc_toks and oc_toks <= sub:
                    notes.append(f"named outcome '{oc}' found in Kalshi market")
                else:
                    pen += 0.35
                    notes.append(f"named outcome '{oc}' not in Kalshi market")
            else:
                side = oc.lower()
            score = 0.65 * cos + 0.35 * ent_recall - pen
            scored.append((score, i, side, cos, ent_recall, notes))

        if not scored:
            return None, reasons + vetoed[:3] + ["no candidate passed consistency checks"]
        scored.sort(key=lambda x: -x[0])
        best = scored[0]
        runner = scored[1] if len(scored) > 1 else None
        c = self.index.cands[best[1]]
        reasons.append(f"best {c.ticker} score={best[0]:.3f} cos={best[3]:.3f} ent={best[4]:.2f}")
        reasons.extend(best[5])
        if best[0] < self.cfg.min_score:
            return None, reasons + [f"below min_score {self.cfg.min_score}"]
        if runner and best[0] - runner[0] < self.cfg.min_margin:
            r = self.index.cands[runner[1]]
            # sibling contracts with the same answer are fine; different contracts are ambiguous
            return None, reasons + [f"ambiguous vs {r.ticker} ({runner[0]:.3f})"]
        return MarketMatch(
            ticker=c.ticker,
            kalshi_side=best[2],
            score=round(best[0], 4),
            method="semantic",
            kalshi_title=f"{c.title} [{c.yes_sub_title}]" if c.yes_sub_title else c.title,
            runner_up=self.index.cands[runner[1]].ticker if runner else None,
            runner_up_score=round(runner[0], 4) if runner else 0.0,
            reasons=reasons,
        ), reasons
