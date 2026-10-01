"""Regression tests for mapper fixes found by replaying 24h of leader trades (Oct 1 2026).

Fixture: a slice of the real Kalshi open-market index captured the same day, so neighbouring
contracts (the ones that used to win wrongly or cause ambiguity) are present.
"""
import json
import os

import pytest

from copytrader.config import MappingConfig
from copytrader.mapping import MarketMapper, districts, ticker_years
from copytrader.models import KalshiCandidate

FIX = os.path.join(os.path.dirname(__file__), "kalshi_snapshot_2026-10-01.json")
DOMAINS = ["politics", "geopolitics", "economics", "weather"]


@pytest.fixture(scope="module")
def mp():
    with open(FIX, encoding="utf-8") as fh:
        cands = [KalshiCandidate(**row) for row in json.load(fh)]
    m = MarketMapper(MappingConfig(overrides_path=None, domains=DOMAINS))
    m.set_candidates(cands)
    return m


def ticker_of(mp, title, outcome="Yes"):
    m, reasons = mp.map(title, outcome)
    return (m.ticker, m.kalshi_side) if m else (None, reasons)


# --- new correct matches -------------------------------------------------------------------

def test_no_change_maps_to_fed_hold(mp):
    assert ticker_of(mp, "Will there be no change in Fed interest rates after the October 2026 meeting?") == \
        ("KXFEDDECISION-26OCT-H0", "yes")


def test_no_change_maps_to_ecb_and_boc_hold(mp):
    assert ticker_of(mp, "Will the ECB announce no change at the October 2026 meeting?", "No") == \
        ("KXCBDECISIONEU-26OCT29-HOLD", "no")
    assert ticker_of(mp, "Will the Bank of Canada make no change to the target for the overnight rate at the "
                         "December interest rate announcement?")[0] == "KXCBDECISIONCANADA-26DEC-H0"


def test_party_senate_market_uses_ticker_year_and_ignores_candidate_subtitle(mp):
    # Kalshi headline has no year and the rules say "term beginning in 2027"; the ticker says 26.
    assert ticker_of(mp, "Will the Republicans win the Georgia Senate race in 2026?") == ("SENATEGA-26-R", "yes")


def test_party_governor_market(mp):
    assert ticker_of(mp, "Will the Democrats win the Ohio governor race in 2026?", "No") == ("GOVPARTYOH-26-D", "no")


# --- wrong matches that used to happen ------------------------------------------------------

def test_house_district_must_match(mp):
    assert ticker_of(mp, "Will the Democratic Party win the OH-07 House seat?")[0] == "KXHOUSERACE-OH07-26-D"
    assert ticker_of(mp, "Will the Democratic Party win the CO-08 House seat?")[0] is None  # not in fixture


def test_highest_temperature_never_maps_to_minimum(mp):
    t, _ = ticker_of(mp, "Will the highest temperature in Miami be between 78-79°F on October 1?")
    assert t is None or not t.startswith("KXLOW")


def test_event_type_must_match(mp):
    assert ticker_of(mp, "Will the U.S. invade Iran before 2027?", "No")[0] is None
    t, _ = ticker_of(mp, "Will Benjamin Netanyahu be the next leader out before 2027?", "No")
    assert t is None or "ARREST" not in t


def test_unsized_cut_question_not_mapped_to_25bp_bucket(mp):
    assert ticker_of(mp, "Fed rate cut by October 2026 meeting?", "No")[0] is None


def test_regional_result_not_mapped_to_national_winner(mp):
    assert ticker_of(mp, "Will Ronaldo Caiado win the most votes in the next Brazil presidential election "
                         "from Goiás?", "No")[0] is None


def test_announcement_contract_not_mapped_to_event(mp):
    assert ticker_of(mp, "Will Anthropic IPO by October 31, 2026?")[0] is None


def test_final_deal_not_mapped_to_any_deal(mp):
    assert ticker_of(mp, "US-Iran Final Nuclear Deal by October 31, 2026?", "No")[0] is None


def test_next_election_market_with_date_ticker_keeps_rules_year(mp):
    # KXSERBIAPARLI-26JUN30 resolves on the *next* election (closes 2027); not the same as "2026 election"
    assert ticker_of(mp, "Will Student List – Students Win win the most seats in the 2026 Serbian "
                         "parliamentary election?")[0] is None


# --- helpers ---------------------------------------------------------------------------------

def test_ticker_years_bare_cycle_codes_only():
    assert ticker_years("SENATEOHS-26", "SENATEOHS-26-R") == {"2026"}
    assert ticker_years("CONTROLH-2026") == {"2026"}
    assert ticker_years("KXSERBIAPARLI-26JUN30") == set()


def test_districts():
    assert districts("Will the Democratic Party win the CO-8 House seat?") == {"CO08"}
    assert districts("OH-07") == {"OH07"}


def test_by_end_of_day_equals_before_next_day():
    from conftest import cand
    rules = "If the United States and Iran sign a ceasefire before Nov 1, 2026, then the market resolves to Yes."
    cands = [cand("KXUSIRANCEASE-26-NOV01", "Will the US and Iran sign a ceasefire before Nov 1, 2026?",
                  "Before Nov 1, 2026", rules=rules),
             cand("KXUSIRANCEASE-26-DEC01", "Will the US and Iran sign a ceasefire before Dec 1, 2026?",
                  "Before Dec 1, 2026", rules=rules.replace("Nov", "Dec"))]
    m = MarketMapper(MappingConfig(overrides_path=None, domains=DOMAINS))
    m.set_candidates(cands)
    hit, r = m.map("Will the US and Iran sign a ceasefire by October 31, 2026?", "Yes")
    assert hit is not None and hit.ticker == "KXUSIRANCEASE-26-NOV01", r
    assert m.map("Will the US and Iran sign a ceasefire by October 30, 2026?", "Yes")[0] is None


def test_cross_year_deadline_needs_matching_year_and_event():
    from conftest import cand
    cands = [
        cand("KXPUTINZELMEET-29JAN01-27JAN01", "Will Putin and Zelenskyy meet in person before Jan 1, 2027?",
             "Before Jan 1, 2027", event_title="When will Putin and Zelenskyy meet?"),
        cand("KXTRUMPCOUNTRIES-27JAN01-RUS", "Will Donald Trump visit Russia before Jan 1, 2027?", "Russia",
             event_title="What countries will Trump visit in 2026?"),
        cand("KXELECTIRAN-27JAN01", "Will Iran hold a presidential election before Jan 1, 2027?",
             "Before Jan 1, 2027", event_title="Will Iran hold a presidential election?"),
    ]
    m = MarketMapper(MappingConfig(overrides_path=None, domains=DOMAINS))
    m.set_candidates(cands)
    assert m.map("Will Putin and Zelenskyy meet by December 31, 2026?", "Yes")[0].ticker == \
        "KXPUTINZELMEET-29JAN01-27JAN01"
    assert m.map("Will Putin and Zelenskyy not meet by December 31, 2027?", "Yes")[0] is None  # wrong year
    assert m.map("Russia military action against an EU country by December 31, 2026?", "No")[0] is None
    assert m.map("Iran leadership change by December 31?", "No")[0] is None  # no year stated


def test_relative_order_question_not_mapped_to_absolute_deadline(mp):
    assert ticker_of(mp, "Will Benjamin Netanyahu be the next leader out before 2027?", "No")[0] is None
