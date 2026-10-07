import argparse, sys
from copytrader.config import Config
from copytrader.polymarket import PolymarketClient
from copytrader.kalshi import KalshiClient
from copytrader.mapping import Mapper
from copytrader.sports import SportsMapper, coverage_report
from copytrader.engine import Engine
from copytrader.ledger import Ledger


def main():
    ap = argparse.ArgumentParser(description="Polymarket top-trader -> Kalshi copy trader (dry-run default)")
    ap.add_argument("--live", action="store_true", help="send real orders (also needs KALSHI_LIVE_CONFIRM=YES_SEND_REAL_ORDERS)")
    ap.add_argument("--verify-ledger", action="store_true")
    ap.add_argument("--check-sports", action="store_true", help="list Kalshi team labels the matcher cannot resolve")
    ap.add_argument("--no-sports", action="store_true")
    ap.add_argument("--top-n", type=int, default=20)
    a = ap.parse_args()
    try:
        from dotenv import load_dotenv; load_dotenv()
    except ImportError:
        pass
    cfg = Config.from_env(top_n=a.top_n, live=a.live)
    if a.verify_ledger:
        ok = Ledger(cfg.ledger_path).verify()
        print("ledger intact" if ok else "LEDGER TAMPERED"); sys.exit(0 if ok else 1)
    if a.check_sports:
        import json
        k0 = KalshiClient(cfg.kalshi_base_url)
        print(json.dumps(coverage_report(k0.series_markets), indent=1)); return
    if a.live and not cfg.live_allowed():
        sys.exit("Refusing: --live also requires KALSHI_LIVE_CONFIRM=YES_SEND_REAL_ORDERS")
    k = KalshiClient(cfg.kalshi_base_url, cfg.kalshi_key_id, cfg.kalshi_private_key_path)
    mf = lambda: Mapper(k.open_markets(), cfg.overrides_path, cfg.min_match_score)
    print("MODE:", "LIVE" if cfg.live_allowed() else "DRY-RUN (no orders will be sent)")
    sports = None if a.no_sports else SportsMapper(k.series_markets, "sports_aliases.json")
    Engine(cfg, PolymarketClient(), k, mf, sports=sports).run()


if __name__ == "__main__":
    main()
