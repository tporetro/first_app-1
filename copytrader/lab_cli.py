"""python lab_cli.py record|settle|forecast|score|loop|pairs|decide|fit|evaluate|daily"""
import argparse, json, os, time, requests, datetime
try:
    from dotenv import load_dotenv; load_dotenv()
except ImportError:
    pass
from copytrader.kalshi import KalshiClient
from copytrader.polymarket import PolymarketClient
from copytrader.config import KALSHI_PROD, KALSHI_DEMO
from lab import db, recorder, forecaster, scoring, pairs, strategy, bridge
from copytrader.ledger import Ledger


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["record", "settle", "forecast", "score", "loop", "pairs", "decide", "fit", "evaluate", "daily", "route", "kalshi-check"])
    ap.add_argument("--db", default=os.getenv("LAB_DB", "lab.db"))
    ap.add_argument("--limit", type=int, default=int(os.getenv("FORECAST_LIMIT", "10")))
    ap.add_argument("--budget", type=float, default=float(os.getenv("FORECAST_BUDGET_USD", "2")), help="max USD of API spend per forecast run")
    ap.add_argument("--model", default=forecaster.MODEL)
    ap.add_argument("--live", action="store_true", help="route: actually send orders (every other lock must also be open)")
    ap.add_argument("--demo-skip-gate", action="store_true", help="route: bypass the evidence gate on Kalshi DEMO only")
    a = ap.parse_args()
    c = db.connect(a.db); base = os.getenv("KALSHI_BASE_URL", KALSHI_DEMO) if a.cmd in ("route", "kalshi-check") else KALSHI_PROD
    k = KalshiClient(base, os.getenv("KALSHI_KEY_ID", "") if a.cmd in ("route", "kalshi-check") else "", os.getenv("KALSHI_PRIVATE_KEY_PATH", "") if a.cmd in ("route", "kalshi-check") else ""); s = requests.Session(); p = PolymarketClient()

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
    elif a.cmd == "kalshi-check":
        import requests as rq
        print("host:", base, "(DEMO, fake money)" if bridge.is_demo(base) else "(PRODUCTION, real money)")
        if not k.authed:
            raise SystemExit("No credentials loaded: set KALSHI_KEY_ID and KALSHI_PRIVATE_KEY_PATH in .env "
                             "(and make sure the .pem file exists at that path).")
        try:
            print(f"OK - authenticated. Buying power: ${k.buying_power_usd():,.2f}")
        except rq.HTTPError as e:
            code = e.response.status_code
            raise SystemExit(f"Kalshi rejected the request ({code}). "
                             + ("401/403: key ID and private key don't match, or the key was made on a different "
                                "site (demo keys only work on the demo host)." if code in (401, 403) else e.response.text[:200]))
    elif a.cmd == "route":
        print(json.dumps(bridge.route(c, k, base, Ledger("ledger/bridge.jsonl"), live=a.live,
                                       demo_skip_gate=a.demo_skip_gate), indent=1))
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
