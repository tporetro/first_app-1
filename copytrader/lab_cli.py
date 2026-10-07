"""python lab_cli.py record|settle|forecast|score|loop"""
import argparse, json, time, requests
from copytrader.kalshi import KalshiClient
from copytrader.polymarket import PolymarketClient
from copytrader.config import KALSHI_PROD
from lab import db, recorder, forecaster, scoring, pairs, strategy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["record", "settle", "forecast", "score", "loop", "pairs", "decide", "fit", "evaluate"])
    ap.add_argument("--db", default="lab.db"); ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--budget", type=float, default=5.0, help="max USD of API spend per forecast run")
    ap.add_argument("--model", default=forecaster.MODEL)
    a = ap.parse_args()
    c = db.connect(a.db); k = KalshiClient(KALSHI_PROD); s = requests.Session(); p = PolymarketClient()

    _ev = {}
    def event_title(t):
        if t not in _ev:
            try: _ev[t] = k._req("GET", f"/events/{t}")["event"]["title"]
            except Exception: _ev[t] = None
        return _ev[t]

    def record():
        print("kalshi", recorder.record_kalshi(c, k), "poly", recorder.record_polymarket(c, s),
              "wallet fills", recorder.record_wallets(c, p), "settled", recorder.settle(c, k, s))
    if a.cmd == "record": record()
    elif a.cmd == "settle": print("settled", recorder.settle(c, k, s))
    elif a.cmd == "forecast":
        import anthropic
        print(forecaster.run(c, anthropic.Anthropic(), a.limit, a.model, a.budget, event_title))
    elif a.cmd == "score": print(json.dumps(scoring.score(c), indent=1, default=str))
    elif a.cmd == "pairs": print("paired", pairs.build_pairs(c, k))
    elif a.cmd == "decide": print("decisions logged", strategy.decide_all(c))
    elif a.cmd == "fit": print(strategy.fit_weights(c) or "need >=30 resolved decisions")
    elif a.cmd == "evaluate": print(json.dumps(strategy.evaluate(c), indent=1, default=str))
    elif a.cmd == "loop":
        while True:
            record(); time.sleep(300)


if __name__ == "__main__":
    main()
