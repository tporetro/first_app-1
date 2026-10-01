# copytrader: Polymarket leaderboard → Kalshi mirror

A framework that watches the top Polymarket traders, finds the equivalent Kalshi contract for
their election and macro trades, and sizes a mirrored Kalshi order. It **runs in dry-run mode by
default.** Every decision goes to a hash-chained, append-only ledger so you can review it before
any real money moves.

```
 Polymarket Data API ──► LeaderTracker (top-N leaderboard, hourly refresh)
                              │ wallets
 RTDS WebSocket (live) ──┐    ▼
 /activity polling ──────┴► FillStream ──► Aggregator ──► MarketMapper ──► Router ──► Ledger
 /positions snapshots ────► PositionTracker   (merge split    (semantic      (sizing,    (hash-chained
                              (diffs → ledger)  fills)          match +        risk caps,   JSONL)
                                                               consistency    IOC order)
                                                               vetoes)           │
                                                                                 ▼
                                                                  Kalshi V2 API (LIVE only)
```

## Layers

| Layer | File | What it does |
|---|---|---|
| Polymarket pipeline | `copytrader/polymarket.py` | Pulls the top N from `/v1/leaderboard` (category, period and sort are configurable). Live fills come from the RTDS WebSocket trade tape, filtered to tracked wallets, with per-wallet `/activity` polling as a backstop. Fills are de-duplicated by tx hash. Startup history is marked as seen so old fills never trigger trades. `/positions` snapshots are diffed to log opens, closes, increases and decreases. |
| Mapping engine | `copytrader/mapping.py` | 1) Macro gate: keeps election, politics and finance markets; drops sports, esports and crypto up/down. 2) Manual overrides from `mapping_overrides.json`. 3) TF-IDF cosine plus entity recall against every open Kalshi market in the Elections, Politics, Economics and Financials categories (~36k markets). 4) **Hard vetoes** for anything that changes the payout: year, numeric threshold, comparator (`>25bps` vs `25bps`), finishing rank (2nd place vs win), round/runoff/primary scope, state legislature vs US Senate. Combo and multi-state bundle products are excluded. 5) Ambiguity guard: the best match must clear `min_score` and beat the runner-up by `min_margin`. |
| Kalshi router | `copytrader/router.py`, `kalshi.py` | Signs requests with Ed25519 or RSA-PSS. Reads the live quote and rejects the pair if Kalshi's price differs from the leader's fill price by more than `max_divergence`, which usually means a mismap or a stale signal. Sizes the order, enforces caps, and sends an IOC order to `POST /portfolio/events/orders` (V2 single-book: `bid` = long YES, `ask` = long NO, price always on the YES leg). When the leader sells, it reduces our mirrored position proportionally (`reduce_only`). |
| Safety | `config.py`, `ledger.py` | Live trading needs three separate opt-ins. Everything is logged to a tamper-evident ledger. |

### Sizing

```
conviction = clamp(leader_usdc / conviction_ref_usdc, min_conviction, 1.0)
notional   = buying_power × bankroll_fraction × conviction
notional   = min(notional, max_order_usd, per-market headroom, daily headroom)
limit      = min(kalshi_ask + slippage, leader_price + max_divergence, max_price)
contracts  = floor(notional / (limit + fee/contract))
```

`buying_power` is your real Kalshi balance when credentials are set; otherwise it is
`paper_balance_usd`. Defaults are 2% per signal, $50 max per order, $150 per market, $300 per day,
and 15 open positions.

## Setup

```bash
cd copytrader
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
cp config.example.json config.json
cp mapping_overrides.example.json mapping_overrides.json   # optional
python -m pytest -q                                        # 34 offline tests
```

Kalshi credentials are optional in dry-run. With them, the dry run sizes against your real balance:

```bash
export KALSHI_API_KEY_ID=...                 # from kalshi.com → Account → API Keys
export KALSHI_PRIVATE_KEY_PATH=~/kalshi.pem  # Ed25519 or RSA private key
```

Set `"kalshi": {"env": "prod"}` to map against production markets. The default is `demo`.

## Usage

```bash
python -m copytrader -c config.json leaderboard            # who we'd track
python -m copytrader -c config.json map "Will the Fed cut rates by 25 bps at the October 2026 meeting?" --outcome Yes
python -m copytrader -c config.json replay --hours 72      # push recent real fills through the pipeline (dry, separate ledger)
python -m copytrader -c config.json run                    # DRY RUN: stream, map, size, log
python -m copytrader -c config.json report                 # review planned orders
python -m copytrader -c config.json verify-ledger          # check the hash chain
python -m copytrader -c config.json dashboard --out data/dashboard.html   # phone-friendly review page
```

### Going live (deliberately hard)

All three are required. If any one is missing, the engine stays in dry-run, and `--live`
without the other two exits with an error:

1. `"dry_run": false` in `config.json`
2. `--live` on the command line
3. `export COPYTRADER_LIVE_CONFIRM=I_ACCEPT_REAL_MONEY_RISK`

Try live mode first against `"env": "demo"` (Kalshi's paper exchange) with demo API keys.

## The ledger

`data/ledger.jsonl` holds one JSON record per line. Each record carries `seq`, `ts`, `mode`
(`DRY_RUN`/`LIVE`), `kind`, `data`, `prev_hash` and `hash = sha256(record without hash)`. Kinds:
`startup`, `leaderboard`, `leader_fill`, `position_change`, `unmapped`, `decision` (skips, with
the reason), `order_planned` (the full signal, match, quote, sizing and exact API payload),
`order_submitted`, `order_error`, `shutdown`.

The file is only ever opened in append mode and fsync'd after each write. If any line is edited,
deleted or reordered, `verify-ledger` fails, and the engine refuses to append to a broken chain.
For OS-level enforcement, run `sudo chattr +a data/ledger.jsonl`.

## Validation on real data

A replay of 72h of fills from the top-20 POLITICS leaderboard covered 962 fills, which aggregated
into 216 signals. Of those, 40 mapped to Kalshi and 22 produced dry-run orders; the rest were
skipped with logged reasons. That replay surfaced mismaps which are now covered by regression
tests in `tests/test_mapping.py`:
US Senate vs state-senate races, "second-most votes" vs "win", and "first round" vs "qualify for
runoff". The price-divergence guard also blocked several bad pairs independently.

## Known limitations and risks: read before going live

- **Resolution criteria differ between venues.** Two contracts that read the same can settle
  differently (sources, deadlines, edge cases). The mapper checks wording, not settlement rules.
  Pin high-value markets in `mapping_overrides.json` after reading both rulebooks.
- **Latency.** You enter after the leader, often at a worse price. The `max_divergence` and
  `slippage` caps limit this but don't remove it. Leaderboard PnL is past performance, and some
  top wallets are market makers whose fills aren't directional bets.
- **Exits** mirror the leader's SELL fills. Redemptions, merges and transfers show up as
  `position_change` entries in the ledger but don't trigger trades.
- **IOC orders** may partially fill or not fill at all. Position state is only updated with what
  actually filled.
- **Eligibility.** Kalshi is a CFTC-regulated US exchange and requires a verified account. This
  tool only *reads* public Polymarket data and never trades on Polymarket. Follow each venue's
  terms of service in your jurisdiction.
- This is engineering tooling, not investment advice. Run it in dry-run long enough to judge the
  signal quality from the ledger before risking capital.
