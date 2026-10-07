# copytrader: Polymarket top traders -> Kalshi (dry-run by default)

Polls the Polymarket leaderboard's top N wallets, detects new BUY fills, maps the
market to the identical Kalshi contract, sizes a small fraction of buying power,
and routes (or, by default, only *logs*) a limit order.

## Run (safe)
    pip install -r requirements.txt
    python run.py                 # DRY-RUN: nothing is ever sent to Kalshi
    python run.py --verify-ledger # check the hash-chained ledger for tampering
    python -m pytest

Plans are written to `ledger/ledger.jsonl` (append-only, hash-chained). Review it
for as long as you like before considering live mode.

## Live (not recommended until the ledger looks right)
Needs Kalshi API credentials (start with the DEMO base URL), `--live`, AND
`KALSHI_LIVE_CONFIRM=YES_SEND_REAL_ORDERS`. Any one missing -> dry-run/refusal.

## Safety layers
- Copies BUYs only, YES/NO markets only, fills >= `min_source_usdc`, signals < 5 min old
- Skips if Kalshi ask is > `max_slippage_cents` above the source's fill price
- Market mapping is conservative: numbers/years must match, negation must match,
  close dates must be near, similarity >= 0.72; `mapping_overrides.json`
  ({polymarket_condition_id: kalshi_ticker}) always wins; optional `verifier` hook
- Per-trade, per-market and daily USD caps (`copytrader/config.py`)

## Known limits (read these)
- You see a fill after it happened; by the time you copy it the edge may be gone.
  The ledger lets you measure that (compare planned price to later prices).
- Leaderboard PnL is partly survivorship/luck; top wallets are often market makers
  or sports bettors. Sports outcomes (team names) are skipped; only YES/NO copied.
- Same-looking markets can resolve differently. Always spot-check matches in the ledger.
- Polymarket and Kalshi availability/legality depends on your jurisdiction.

---

# Signal lab: recorder + blind AI forecaster

    python lab_cli.py record      # snapshot Kalshi (liquid, <7d, no parlays) + Polymarket + top-wallet fills; settle resolved
    python lab_cli.py loop        # record every 5 min (run under pm2/systemd on the server)
    ANTHROPIC_API_KEY=... python lab_cli.py forecast --limit 10 --budget 2
    python lab_cli.py score       # AI vs market: Brier, log loss, calibration, paper PnL after fees

How to read it honestly:
- The forecaster is **blind**: Claude (web search on) never sees the market price, so its
  probability is an independent signal. `score` compares its Brier score to the market's.
  `ai_beats_market: true` over a few hundred resolved markets is the first real evidence of edge.
- Paper PnL buys at the ask / sells at the bid minus a 2c friction, only when |AI - market| >= 5c.
- `--budget` hard-caps API spend per run; default model `claude-opus-5-5` (override with
  `FORECAST_MODEL`, e.g. a cheaper model for wide sweeps). Cost per forecast is stored per row.
- Nothing here places orders.

---

# The combined strategy (`lab/strategy.py`)

    logit(p) = logit(market mid) + w_ai*x_ai + w_xv*x_xv + w_flow*x_flow

| signal | meaning |
|---|---|
| `x_ai` | blind Claude forecast vs market price (log-odds gap) |
| `x_xv` | the same event's price on the *other* venue vs this one (needs `pairs`) |
| `x_flow` | net size-weighted buying by tracked top wallets toward this outcome (6h window) |

With no signals, p equals the market price. Weights start as small priors
(0.35 / 0.30 / 0.15) and are refit by ridge logistic regression on **resolved** history,
so a signal only gains influence after it has been right. Trades need edge > 4c *after*
Kalshi's fee and slippage, are sized with 1/4 Kelly, and are capped at 2% of bankroll.

    python lab_cli.py loop            # record continuously
    python lab_cli.py pairs           # match the same event across venues
    python lab_cli.py forecast        # blind AI forecasts
    python lab_cli.py decide          # log combined decision per market (point-in-time, no look-ahead)
    python lab_cli.py fit             # refit weights from resolved markets (needs >= 30)
    python lab_cli.py evaluate        # Brier vs market + bootstrap PnL + the real-money gate

**Real-money gate** (`ready_for_real_money`): >= 200 resolved markets, >= 100 simulated
trades, combined Brier beats the market's, and the 5th-percentile bootstrap PnL is > 0.
Until it says true, everything is paper. The tests check that a noise-only signal
does NOT pass the gate and an informative one does.
