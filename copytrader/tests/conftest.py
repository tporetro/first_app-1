import os
import sys
import time

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from copytrader.models import KalshiCandidate, LeaderTrade  # noqa: E402


def cand(ticker, title, sub="", event_title="", close="2026-12-31T00:00:00Z", series=None, rules="",
         event=None):
    return KalshiCandidate(ticker, event or ticker.rsplit("-", 1)[0], series or ticker.split("-")[0], "Economics",
                           title, event_title or title, sub, "", close, rules)


CANDS = [
    cand("KXFEDDECISION-26OCT-C25", "Will the Federal Reserve Cut rates by 25bps at their October 2026 meeting?",
         "Cut 25bps", close="2026-10-28T18:59:00Z"),
    cand("KXFEDDECISION-26OCT-C26", "Will the Federal Reserve Cut rates by >25bps at their October 2026 meeting?",
         "Cut >25bps", close="2026-10-28T18:59:00Z"),
    cand("KXFEDDECISION-26OCT-H0", "Will the Federal Reserve Hike rates by 0bps at their October 2026 meeting?",
         "Fed maintains rate", close="2026-10-28T18:59:00Z"),
    cand("KXFEDDECISION-26DEC-C25", "Will the Federal Reserve Cut rates by 25bps at their December 2026 meeting?",
         "Cut 25bps", close="2026-12-09T18:59:00Z"),
    cand("CONTROLS-2026-R", "Will Republicans win the U.S. Senate in 2026?", "Republican Party"),
    cand("CONTROLS-2026-D", "Will Democrats win the U.S. Senate in 2026?", "Democratic Party"),
    cand("CONTROLH-2026-D", "Will Democrats win the House in 2026?", "Democratic Party"),
    cand("KXRECSSNBER-26", "Will there be a recession in 2026?", "Starts", event="KXRECSSNBER-26"),
    cand("KXRECSSNBER-27", "Will there be a recession in 2027?", "Starts", close="2028-01-31T00:00:00Z",
         event="KXRECSSNBER-27"),
    cand("KXBALANCEPOWERCOMBO-27FEB-RR", "Republicans win Senate and Republicans win House in 2026?", "R Senate, R House",
         series="KXBALANCEPOWERCOMBO"),
    cand("KXNYCMAYOR-25-ZM", "Who will win the NYC mayoral election in 2025?", "Zohran Mamdani",
         event_title="NYC Mayor 2025"),
    cand("KXNYCMAYOR-25-AC", "Who will win the NYC mayoral election in 2025?", "Andrew Cuomo",
         event_title="NYC Mayor 2025"),
]


def trade(title="Will the Fed cut rates by 25 bps at the October 2026 meeting?", outcome="Yes",
          side="BUY", size=10000.0, price=0.62, wallet="0xabc", ts=None, tx="0xtx1", asset="111",
          cid="0xcid"):
    return LeaderTrade(wallet, side, asset, cid, outcome, 0, size, price,
                       int(ts if ts is not None else time.time()), title, "slug", "event-slug", tx)


@pytest.fixture
def candidates():
    return list(CANDS)
