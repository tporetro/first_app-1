"""Command line entry point: ``python -m copytrader <command>``."""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import Counter

from . import ledger as ledger_mod
from .config import load_config, resolve_live_mode
from .kalshi import KalshiClient
from .mapping import MarketMapper
from .polymarket import DataAPI

log = logging.getLogger("copytrader")


def _setup_logging(level: str) -> None:
    logging.basicConfig(level=getattr(logging, level.upper(), logging.INFO),
                        format="%(asctime)s %(levelname)-5s %(name)s: %(message)s")


def cmd_run(args, cfg) -> int:
    from .engine import Engine

    live, banner = resolve_live_mode(cfg, args.live)
    if args.live and not live:
        log.error("--live requested but not all live gates are satisfied: %s", banner)
        return 2
    mode = "LIVE" if live else "DRY_RUN"
    log.warning("=" * 70)
    log.warning("MODE: %s", banner)
    log.warning("Ledger: %s", os.path.abspath(cfg.ledger_path))
    log.warning("=" * 70)
    kalshi = KalshiClient(cfg.kalshi)
    if live and not kalshi.authenticated:
        log.error("Live mode needs Kalshi credentials (%s, %s)", cfg.kalshi.key_id_env,
                  cfg.kalshi.private_key_path_env)
        return 2
    led = ledger_mod.Ledger(cfg.ledger_path, mode)
    led.append("startup", {"mode": mode, "banner": banner, "config": cfg.to_dict()})
    eng = Engine(cfg, kalshi, led, live, base_dir=os.path.dirname(os.path.abspath(args.config or ".")))
    eng.run(once=args.once, duration_s=args.duration)
    return 0


def cmd_serve(args, cfg) -> int:
    from .engine import Engine
    from .serve import serve

    live, banner = resolve_live_mode(cfg, args.live)
    if args.live and not live:
        log.error("--live requested but not all live gates are satisfied: %s", banner)
        return 2
    mode = "LIVE" if live else "DRY_RUN"
    log.warning("MODE: %s | ledger %s", banner, os.path.abspath(cfg.ledger_path))
    kalshi = KalshiClient(cfg.kalshi)
    if live and not kalshi.authenticated:
        log.error("Live mode needs Kalshi credentials")
        return 2
    led = ledger_mod.Ledger(cfg.ledger_path, mode)
    led.append("startup", {"mode": mode, "banner": banner, "config": cfg.to_dict(), "server": True})
    base = os.path.dirname(os.path.abspath(args.config or "."))
    serve(lambda: Engine(cfg, kalshi, led, live, base_dir=base), cfg.ledger_path,
          os.path.join(os.path.dirname(cfg.ledger_path), "dashboard.html"),
          int(os.environ.get("PORT", args.port)))
    return 0


def cmd_leaderboard(args, cfg) -> int:
    api = DataAPI(cfg.polymarket.data_api)
    for cat in ([args.category] if args.category else cfg.polymarket.leaderboard_categories):
        print(f"== {cat}")
        for l in api.leaderboard(cat, cfg.polymarket.leaderboard_period, cfg.polymarket.leaderboard_order_by,
                                 cfg.polymarket.top_n):
            print(f"#{l.rank:<3} {l.name[:28]:<28} pnl=${l.pnl:>14,.0f} vol=${l.volume:>16,.0f}  {l.wallet}")
    return 0


def cmd_map(args, cfg) -> int:
    kalshi = KalshiClient(cfg.kalshi)
    mapper = MarketMapper(cfg.mapping, kalshi,
                          os.path.dirname(os.path.abspath(args.config or ".")))
    mapper.refresh_index(force=True)
    match, reasons = mapper.map(args.question, args.outcome)
    print(json.dumps({"match": match.to_dict() if match else None, "reasons": reasons}, indent=2))
    return 0


def cmd_replay(args, cfg) -> int:
    """Push the leaders' recent fills through mapping + routing (always dry-run, separate ledger).

    Quotes are *current* Kalshi prices, not historical ones, so this validates the
    mapping and sizing logic -- it is not a P&L backtest.
    """
    import time

    from .engine import Engine

    cfg.dry_run = True
    cfg.polymarket.signal_max_age_s = args.hours * 3600 + 60
    cfg.state_path = os.path.join(os.path.dirname(cfg.ledger_path), "replay_state.json")
    if os.path.exists(cfg.state_path):
        os.remove(cfg.state_path)
    led = ledger_mod.Ledger(args.ledger or cfg.ledger_path.replace(".jsonl", f".replay-{int(time.time())}.jsonl"),
                            "DRY_RUN")
    eng = Engine(cfg, KalshiClient(cfg.kalshi), led, live=False)
    eng.tracker.refresh(force=True)
    eng.mapper.refresh_index(force=True)
    cutoff = time.time() - args.hours * 3600
    fills = []
    for w in eng.tracker.wallets():
        try:
            fills += [t for t in eng.api.trades(w, limit=200) if t.timestamp >= cutoff]
        except Exception as e:  # noqa: BLE001
            log.warning("fetch failed for %s: %s", w, e)
    fills.sort(key=lambda t: t.timestamp)
    for t in fills:
        eng.process_trade(t)
    for sig in eng.agg.flush(force=True):
        eng.process_signal(sig)
    print(f"\nreplayed {len(fills)} fills -> {eng.stats}\nledger: {led.path}")
    return 0


def cmd_dashboard(args, cfg) -> int:
    from .dashboard import render

    sources = [(p, n) for p, n in zip(args.ledger, args.name or [])] if args.name else \
        [(p, os.path.basename(p)) for p in (args.ledger or [cfg.ledger_path])]
    print(render(sources, args.out))
    return 0


def cmd_verify(args, cfg) -> int:
    path = args.ledger or cfg.ledger_path
    res = ledger_mod.verify(path)
    if res.ok:
        print(f"OK: {res.records} records, chain intact. head={res.last_hash}")
        return 0
    print(f"CORRUPTED after {res.records} valid records: {res.error}")
    return 1


def cmd_report(args, cfg) -> int:
    path = args.ledger or cfg.ledger_path
    kinds, orders, spend = Counter(), [], 0.0
    for rec in ledger_mod.iter_records(path):
        kinds[rec["kind"]] += 1
        if rec["kind"] == "order_planned":
            o, s = rec["data"]["order"], rec["data"]["signal"]
            orders.append(rec)
            if o["action"] == "open":
                spend += o["est_cost"] + o["est_fee"]
            print(f"{rec['ts']} [{rec['mode']}] {o['action'].upper():6} {o['count']:>4} x "
                  f"{o['ticker']:<34} {o['outcome_side'].upper():3} @ {o['limit_price']:.2f} "
                  f"(${o['est_cost']:.2f}) <- {s['leader_name']} {s['side']} '{s['title'][:50]}'")
    print("\nrecord counts:", dict(kinds))
    print(f"planned orders: {len(orders)}  planned entry spend: ${spend:,.2f}")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="copytrader", description=__doc__)
    p.add_argument("--config", "-c", default=os.environ.get("COPYTRADER_CONFIG"))
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="run the copy-trading engine (dry-run unless all live gates set)")
    r.add_argument("--live", action="store_true", help="request live trading (also needs config + env gate)")
    r.add_argument("--once", action="store_true", help="bootstrap, process one aggregation window, exit")
    r.add_argument("--duration", type=float, help="stop after N seconds")
    sv = sub.add_parser("serve", help="always-on: run the engine forever + serve the dashboard over HTTP")
    sv.add_argument("--live", action="store_true")
    sv.add_argument("--port", type=int, default=8080)
    sub.add_parser("leaderboard", help="print tracked leaders").add_argument("--category")
    m = sub.add_parser("map", help="debug the Polymarket->Kalshi mapper")
    m.add_argument("question")
    m.add_argument("--outcome", default="Yes")
    rep = sub.add_parser("replay", help="dry-run the leaders' recent fills through the pipeline")
    rep.add_argument("--hours", type=float, default=24)
    rep.add_argument("--ledger")
    d = sub.add_parser("dashboard", help="render ledger(s) into a phone-friendly HTML page")
    d.add_argument("--ledger", action="append", help="ledger path (repeatable)")
    d.add_argument("--name", action="append", help="tab name for each --ledger, in order")
    d.add_argument("--out", default="data/dashboard.html")
    v = sub.add_parser("verify-ledger", help="verify the hash chain")
    v.add_argument("--ledger")
    rp = sub.add_parser("report", help="summarise planned/executed orders from the ledger")
    rp.add_argument("--ledger")

    args = p.parse_args(argv)
    cfg = load_config(args.config)
    _setup_logging(cfg.log_level)
    if args.config:
        # Relative paths in the config are relative to the config file.
        base = os.path.dirname(os.path.abspath(args.config))
        for attr in ("ledger_path", "state_path"):
            val = getattr(cfg, attr)
            if not os.path.isabs(val):
                setattr(cfg, attr, os.path.join(base, val))
    data_dir = os.environ.get("DATA_DIR")  # persistent disk on a server
    if data_dir:
        cfg.ledger_path = os.path.join(data_dir, os.path.basename(cfg.ledger_path))
        cfg.state_path = os.path.join(data_dir, os.path.basename(cfg.state_path))
    handlers = {"serve": cmd_serve, "run": cmd_run, "leaderboard": cmd_leaderboard, "map": cmd_map,
                "verify-ledger": cmd_verify, "report": cmd_report, "replay": cmd_replay,
                "dashboard": cmd_dashboard}
    return handlers[args.cmd](args, cfg)


if __name__ == "__main__":
    sys.exit(main())
