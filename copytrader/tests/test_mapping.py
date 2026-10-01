import json

from copytrader.config import MappingConfig
from conftest import cand
from copytrader.mapping import MarketMapper, is_macro, numbers


def mapper(cands, **kw):
    m = MarketMapper(MappingConfig(overrides_path=None, **kw))
    m.set_candidates(cands)
    return m


def test_macro_gate():
    assert is_macro("Will the Fed cut rates in October?")[0]
    assert is_macro("Who will win the 2026 Senate race in Ohio?")[0]
    assert not is_macro("Will Deportivo Alavés win on 2026-09-15?", "lal-ala-val-2026-09-15")[0]
    assert not is_macro("Bitcoin Up or Down - September 30, 10:55PM ET", "btc-updown-5m")[0]
    assert not is_macro("NBA: Lakers vs Celtics", "nba-lal-bos")[0]


def test_numbers_ignore_dates_and_years():
    assert numbers("Fed cuts 25 bps on 2026-10-28 (Oct 28, 2026)?") == {25.0}
    assert numbers("Cut >25bps") == {25.0}


def test_fed_cut_maps_to_exact_bucket(candidates):
    m, reasons = mapper(candidates).map("Will the Fed cut rates by 25 bps at the October 2026 meeting?", "Yes")
    assert m is not None, reasons
    assert m.ticker == "KXFEDDECISION-26OCT-C25" and m.kalshi_side == "yes"


def test_no_outcome_maps_to_kalshi_no(candidates):
    m, _ = mapper(candidates).map("Republicans win the Senate in 2026?", "No")
    assert m.ticker == "CONTROLS-2026-R" and m.kalshi_side == "no"


def test_year_disambiguates(candidates):
    m, reasons = mapper(candidates).map("US recession in 2026?", "Yes")
    assert m is not None, reasons
    assert m.ticker == "KXRECSSNBER-26"


def test_named_outcome_resolves_to_sub_market(candidates):
    m, reasons = mapper(candidates).map("NYC Mayoral Election 2025 winner", "Zohran Mamdani")
    assert m is not None, reasons
    assert m.ticker == "KXNYCMAYOR-25-ZM" and m.kalshi_side == "yes"


def test_combo_markets_never_matched(candidates):
    m, _ = mapper(candidates).map("Republicans win Senate and Republicans win House in 2026?", "Yes")
    assert m is None or "COMBO" not in m.ticker


def test_sports_rejected(candidates):
    m, reasons = mapper(candidates).map("Will Liverpool FC win on 2026-09-12?", "Yes")
    assert m is None


def test_low_similarity_rejected(candidates):
    m, _ = mapper(candidates).map("Will Taylor Swift announce a new album in 2026?", "Yes")
    assert m is None


def test_overrides(tmp_path, candidates):
    p = tmp_path / "ov.json"
    p.write_text(json.dumps({
        "condition_id": {"0xABC": {"ticker": "KXFOO-1", "invert": True}},
        "slug": {"btc-up": {"ticker": "KXBTC-1", "outcomes": {"Up": "yes", "Down": "no"}}},
    }))
    m = MarketMapper(MappingConfig(overrides_path=str(p)))
    m.set_candidates(candidates)
    r, _ = m.map("anything", "Yes", condition_id="0xabc")
    assert (r.ticker, r.kalshi_side, r.method) == ("KXFOO-1", "no", "override")
    r, _ = m.map("Bitcoin up or down", "Down", slug="btc-up")
    assert (r.ticker, r.kalshi_side) == ("KXBTC-1", "no")


# Regression cases taken from a replay of real leaderboard fills.
REAL = [
    cand("KXSTATELEG-OHSEN26-R", "Who will win the Ohio State Senate?", "Republican party"),
    cand("SENATEOH-26-R", "Will Republicans win the Ohio Senate race in 2026?", "Republican party"),
    cand("KXSAOPAULOSENATE-26OCT04-STEB", "Will Simone Tebet win the 2026 São Paulo Federal Senate election?",
         "Simone Tebet"),
    cand("KXBRPRESIDENT5-BRPRES26-5-LSIL",
         "Will Luiz Inácio Lula da Silva finish 5th in the first round of the 2026 Brazilian presidential election?",
         "Luiz Inácio Lula da Silva"),
    cand("KXBRPRESADVANCE-26OCT04-FBOL",
         "Will Flavio Bolsonaro qualify for the runoff in the 2026 Brazilian presidential election?",
         "Flavio Bolsonaro"),
    cand("KXTHREESTATESEN-26NOV03-FTF", "Will Republicans win Kansas?", "Kansas", series="KXTHREESTATESEN"),
]


def test_us_senate_not_mapped_to_state_legislature():
    m, r = mapper(REAL).map("Will the Republicans win the Ohio Senate race in 2026?", "Yes")
    assert m is not None and m.ticker == "SENATEOH-26-R", r


def test_rank_qualifier_blocks_wrong_finish():
    assert mapper(REAL).map("Will Simone Tebet win the second-most votes in the 2026 São Paulo Senate election?",
                            "No")[0] is None
    assert mapper(REAL).map("Will Luiz Inácio Lula da Silva win the first round of the 2026 Brazilian "
                            "presidential election?", "No")[0] is None


def test_first_round_not_runoff():
    assert mapper(REAL).map("Will Flavio Bolsonaro win the most votes in the first round of the 2026 "
                            "Brazil presidential election?", "Yes")[0] is None


def test_multi_state_bundles_excluded():
    m, _ = mapper(REAL).map("Will the Republicans win the Kansas Senate race in 2026?", "No")
    assert m is None or "THREESTATE" not in m.ticker
