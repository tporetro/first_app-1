"""Semantic correlation layer: Polymarket market -> identical Kalshi market.

Deliberately conservative: a wrong match means trading a different contract, so
we only match when text similarity is high AND hard facts (numbers, years,
negation, close date) agree. Manual overrides always win. `verifier` is an
optional hook (e.g. an LLM check of resolution rules) that can veto a match.
"""
import json, os, re
from datetime import datetime

STOP = {"will", "the", "a", "an", "of", "in", "on", "by", "to", "be", "is", "at", "for", "and",
        "or", "than", "before", "after", "it", "its", "this", "that", "with", "as", "any"}
NEG = {"not", "no", "never", "without", "fail"}


def tokens(text: str) -> list:
    return [t for t in re.findall(r"[a-z0-9\.%]+", text.lower()) if t not in STOP]


def facts(text: str) -> set:
    return set(re.findall(r"\d+(?:\.\d+)?%?", text.lower()))


def similarity(a: str, b: str) -> float:
    ta, tb = set(tokens(a)), set(tokens(b))
    if not ta or not tb:
        return 0.0
    jac = len(ta & tb) / len(ta | tb)
    containment = len(ta & tb) / min(len(ta), len(tb))
    return 0.5 * jac + 0.5 * containment


def _close_dt(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def kalshi_text(m: dict) -> str:
    return " ".join(filter(None, [m.get("title"), m.get("yes_sub_title"), m.get("subtitle")]))


class Mapper:
    def __init__(self, kalshi_markets, overrides_path=None, min_score=0.72, verifier=None,
                 max_close_gap_days=3):
        self.markets = kalshi_markets
        self.min_score = min_score
        self.verifier = verifier
        self.max_gap = max_close_gap_days
        self.overrides = {}
        if overrides_path and os.path.exists(overrides_path):
            self.overrides = json.load(open(overrides_path))

    def match(self, poly_title, poly_condition_id="", poly_end=None):
        """Return (kalshi_market, score) or (None, best_score)."""
        if poly_condition_id in self.overrides:
            t = self.overrides[poly_condition_id]
            for m in self.markets:
                if m["ticker"] == t:
                    return m, 1.0
        best, best_s = None, 0.0
        pf = facts(poly_title)
        pneg = bool(set(tokens(poly_title)) & NEG)
        for m in self.markets:
            kt = kalshi_text(m)
            s = similarity(poly_title, kt)
            if s <= best_s:
                continue
            if facts(kt) != pf:                       # thresholds / years must agree exactly
                continue
            if bool(set(tokens(kt)) & NEG) != pneg:   # negation mismatch -> opposite contract
                continue
            if poly_end and m.get("close_time"):
                a, b = _close_dt(poly_end), _close_dt(m["close_time"])
                if a and b and abs((a - b).days) > self.max_gap:
                    continue
            best, best_s = m, s
        if best and best_s >= self.min_score:
            if self.verifier and not self.verifier(poly_title, best):
                return None, best_s
            return best, best_s
        return None, best_s
