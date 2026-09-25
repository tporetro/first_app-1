# StormSignal fixes

Corrected versions of two files from the StormSignal (Manus) project. Each
is a drop-in replacement for its original.

- `server/marketPipeline.ts` replaces `server/marketPipeline.ts`.
- `storm_nodal_backtest.py` replaces the research backtest script.
- `server/xweatherAdapter.ts` is new: the live Xweather storm feed.

## What changed

**Pipeline**
- MISO load hours are hour-ending EST (UTC-5 all year), not UTC. The
  operating date comes from the response's RefId, or from the EST date at
  fetch time.
- MISO prices are labelled with the RefId interval instead of the fetch time.
  RefId intervals are treated as interval-ending; check this against a live
  response.
- NOAA Storm Events times are built from BEGIN/END_YEARMONTH, _DAY and _TIME
  in the zone's standard-time offset (CZ_TIMEZONE). Rows with an unknown zone
  are dropped.
- The walk-forward history for an interval only includes prices published by
  the MISO day-ahead deadline (10:30 EST the day before). It is built per
  location, and the storm adjustment is a least-squares slope.

**Backtest**
- One virtual position per location and operating day, decided at the
  day-ahead deadline. The old version opened overlapping 6-hour trades every
  hour.
- Features use only data available at the deadline. Storm fields count from
  their data_vintage; load and prices count from interval end plus a
  publication lag. Actual load is no longer used on the day it happens.
- Standardization is fitted on the training period only.
- Direction is chosen on the validation period, and results are reported on
  the test period only.
- Losses are no longer capped, and the summary reports the worst trade.

**Xweather adapter** (`server/xweatherAdapter.ts`)
- Polls `/alerts/{lat},{lon}` and `/stormcells/closest` for each watched
  location. It needs `XWEATHER_CLIENT_ID` and `XWEATHER_CLIENT_SECRET`, and
  network access to `data.api.xweather.com`.
- Stamps each response with the time it arrived (`receivedAt`). Downstream
  features must use that as the availability time.
- Removes the client secret from stored URLs, stored bodies and error messages.
- `toSourceObject` maps a response to the existing `source_objects` table.
  `alertToStormRow` and `stormCellToStormRow` map items to `storm_events`
  rows. Insert those with ignore-on-duplicate so the first-seen time is kept.
- Field names follow Xweather's documented response format. They have not yet
  been checked against a live response.

## Tests

    npx vitest run stormsignal/server        # 22 tests
    python -m pytest stormsignal             # 8 tests (needs numpy, pandas)
