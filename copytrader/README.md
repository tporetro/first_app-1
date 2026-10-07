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
