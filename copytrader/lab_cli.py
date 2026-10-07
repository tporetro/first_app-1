"""python lab_cli.py record|settle|forecast|score|loop|pairs|decide|fit|evaluate|daily"""
import argparse, json, os, time, requests, datetime
try:
    from dotenv import load_dotenv; load_dotenv()
except ImportError:
    pass
from copytrader.kalshi import KalshiClient
from copytrader.polymarket import PolymarketClient
from copytrader.config import KALSHI_PROD
from lab import db, recorder, forecaster, scoring, pairs, strategy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["record", "settle", "forecast", "score", "loop", "pairs", "decide", "fit", "evaluate", "daily"])
    ap.add_argument("--db", default=os.getenv("LAB_DB", "lab.db"))
    ap.add_argument("--limit", type=int, default=int(os.getenv("FORECAST_LIMIT", "10")))
    ap.add_argument("--budget", type=float, default=float(os.getenv("FORECAST_BUDGET_USD", "2")), help="max USD of API spend per forecast run")
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
        res = {}
        for name, fn in (("kalshi", lambda: recorder.record_kalshi(c, k)),
                         ("poly", lambda: recorder.record_polymarket(c, s)),
                         ("wallet_fills", lambda: recorder.record_wallets(c, p)),
                         ("settled", lambda: recorder.settle(c, k, s))):
            try:                                   # each step fails independently
                res[name] = fn()
            except Exception as e:
                res[name] = f"ERR {repr(e)[:80]}"
        print(datetime.datetime.now().isoformat(timespec="seconds"), res)
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
    elif a.cmd == "daily":
        os.makedirs("reports", exist_ok=True)
        fitted = strategy.fit_weights(c)
        spend = c.execute("SELECT COALESCE(SUM(cost_usd),0) FROM forecasts").fetchone()[0]
        out = {"date": str(datetime.date.today()), "fitted_weights": fitted, "ai_vs_market": scoring.score(c),
               "combined": strategy.evaluate(c), "total_api_spend_usd": spend,
               "rows": {t: c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                        for t in ("markets", "snapshots", "wallet_trades", "forecasts", "pairs", "features")}}
        path = f"reports/daily-{out['date']}.json"
        json.dump(out, open(path, "w"), indent=1, default=str)
        print(json.dumps(out, indent=1, default=str)); print("saved", path)
    elif a.cmd == "loop":
        while True:
            try:
                record()
            except Exception as e:             # network blips must not kill the recorder
                print("record error:", repr(e)[:200])
            time.sleep(300)


if __name__ == "__main__":
    main()
