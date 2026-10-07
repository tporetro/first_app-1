import json, os, time
from .ledger import Ledger
from .risk import Risk


class Engine:
    def __init__(self, cfg, poly, kalshi, mapper_factory, ledger=None):
        self.cfg, self.poly, self.kalshi = cfg, poly, kalshi
        self.mapper_factory = mapper_factory
        self.ledger = ledger or Ledger(cfg.ledger_path)
        self.risk = Risk(cfg)
        self.live = cfg.live_allowed()
        self.seen = self._load_seen()
        self.mapper = None

    def _load_seen(self):
        p = self.cfg.state_path
        return set(json.load(open(p))) if os.path.exists(p) else set()

    def _save_seen(self):
        os.makedirs(os.path.dirname(self.cfg.state_path) or ".", exist_ok=True)
        json.dump(sorted(self.seen), open(self.cfg.state_path, "w"))

    def bankroll(self):
        if self.kalshi.authed:
            try:
                return self.kalshi.buying_power_usd()
            except Exception as e:
                self.ledger.append("warn", {"msg": f"balance lookup failed: {e}"})
        return self.cfg.simulated_bankroll_usd

    def start(self):
        mode = "LIVE" if self.live else "DRY_RUN"
        self.ledger.append("start", {"mode": mode, "kalshi": self.cfg.kalshi_base_url})
        self.mapper = self.mapper_factory()
        self.traders = self.poly.top_traders(self.cfg.top_n, self.cfg.leaderboard_period)
        self.ledger.append("traders", {"wallets": self.traders})
        # baseline: do not copy history that existed before we started
        for t in self.traders:
            for tr in self.poly.recent_trades(t["wallet"]):
                self.seen.add(tr["id"])
        self._save_seen()

    def tick(self, now=None):
        now = now or time.time()
        for t in self.traders:
            try:
                trades = self.poly.recent_trades(t["wallet"])
            except Exception as e:
                self.ledger.append("warn", {"msg": f"poll {t['wallet']}: {e}"})
                continue
            for tr in sorted(trades, key=lambda x: x["ts"]):
                if tr["id"] in self.seen:
                    continue
                self.seen.add(tr["id"])
                self.handle(tr, t, now)
        self._save_seen()

    def handle(self, tr, trader, now):
        c = self.cfg
        def skip(reason, **extra):
            self.ledger.append("skip", {"reason": reason, "trade": tr, **extra})
        if tr["side"] != "BUY":
            return skip("not a BUY (sells are not mirrored)")
        if tr["usdc"] < c.min_source_usdc:
            return skip("source fill too small")
        if now - tr["ts"] > c.max_signal_age_s:
            return skip("signal stale")
        if tr["outcome"].lower() not in ("yes", "no"):
            return skip("non yes/no outcome")
        market, score = self.mapper.match(tr["title"], tr["condition_id"])
        if not market:
            return skip("no confident Kalshi match", best_score=round(score, 3))
        side = tr["outcome"].lower()
        from .kalshi import _cents
        ask = _cents(self.kalshi.market(market["ticker"]), "yes_ask" if side == "yes" else "no_ask")
        if ask is None:
            return skip("no ask on Kalshi", ticker=market["ticker"])
        src_cents = round(tr["price"] * 100)
        if ask > src_cents + c.max_slippage_cents:
            return skip("Kalshi ask too far above source fill", ask=ask, source=src_cents,
                        ticker=market["ticker"])
        n, why = self.risk.size(self.bankroll(), ask, market["ticker"])
        if n == 0:
            return skip(why, ticker=market["ticker"])
        plan = {"source": trader, "trade": tr, "ticker": market["ticker"], "side": side,
                "count": n, "limit_cents": ask, "match_score": round(score, 3),
                "usd": round(n * ask / 100, 2)}
        res = self.kalshi.place_limit_buy(market["ticker"], side, n, ask, live=self.live)
        self.risk.record(market["ticker"], plan["usd"])
        self.ledger.append("order_live" if self.live else "order_planned", {**plan, "result": res})

    def run(self):
        self.start()
        while True:
            self.tick()
            time.sleep(self.cfg.poll_seconds)
