"""Storm-informed nodal power research scaffold.

This module does not download or fabricate data. It expects a prepared CSV with
market, weather, storm, and outage features. It creates three transparent
signals corresponding to:
  1) storm-driven congestion/outage;
  2) weather-to-load forecast error;
  3) restoration-duration volatility.

Each paper trade is one virtual DART position per location and operating day,
decided at the day-ahead bid deadline on the previous day. Features use only
data available at that deadline:
  - storm and outage fields become available at the row's data_vintage;
  - real-time load and prices become available at interval end plus
    publication_lag_hours.

The CSV's timestamp_utc is the interval-ending time. The output is a
paper-research event study, not an execution system.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import time
from pathlib import Path
from typing import Dict, Optional, Tuple

import numpy as np
import pandas as pd


REQUIRED_COLUMNS = {
    "timestamp_utc",
    "market",
    "location",
    "da_lmp",
    "rt_lmp",
    "load_forecast_mw",
    "load_actual_mw",
    "storm_id",
    "max_wind_mph",
    "hail_size_in",
    "storm_distance_mi",
    "outage_customers",
    "generation_outage_mw",
    "transmission_constraint",
    "data_vintage",
}

STORM_COLUMNS = [
    "max_wind_mph",
    "hail_size_in",
    "storm_distance_mi",
    "outage_customers",
    "generation_outage_mw",
    "transmission_constraint",
]


@dataclass(frozen=True)
class BacktestConfig:
    market: str = "PJM"
    # Market clock for operating days and the bid deadline. PJM runs on
    # prevailing Eastern time; for MISO use "Etc/GMT+5" (EST all year).
    market_timezone: str = "America/New_York"
    da_deadline_local: time = time(10, 30)
    # Operating-day hours (local, hour starting) covered by each position.
    delivery_hours: Tuple[int, int] = (0, 24)
    publication_lag_hours: float = 1.0
    load_error_lookback_hours: int = 24
    signal_quantile: float = 0.80
    min_validation_trades: int = 10
    slippage_per_mwh: float = 1.00
    position_mw: float = 1.0


def load_data(path: str | Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    missing = sorted(REQUIRED_COLUMNS - set(df.columns))
    if missing:
        raise ValueError(f"Missing required columns: {missing}")

    df["timestamp_utc"] = pd.to_datetime(df["timestamp_utc"], utc=True)
    df["data_vintage"] = pd.to_datetime(df["data_vintage"], utc=True)
    df = df.sort_values(["location", "timestamp_utc"]).reset_index(drop=True)
    df["da_rt_spread"] = df["rt_lmp"] - df["da_lmp"]
    df["load_error_mw"] = df["load_actual_mw"] - df["load_forecast_mw"]
    return df


def add_operating_day(df: pd.DataFrame, config: BacktestConfig) -> pd.DataFrame:
    """Tag each row with its local operating day and hour-starting."""
    out = df.copy()
    start_local = (out["timestamp_utc"] - pd.Timedelta(hours=1)).dt.tz_convert(config.market_timezone)
    out["operating_day"] = start_local.dt.tz_localize(None).dt.normalize()
    out["local_hour"] = start_local.dt.hour
    return out


def decision_time_utc(operating_day: pd.Series, config: BacktestConfig) -> pd.Series:
    """Day-ahead deadline for each operating day, in UTC."""
    deadline = operating_day - pd.Timedelta(days=1) + pd.Timedelta(
        hours=config.da_deadline_local.hour, minutes=config.da_deadline_local.minute
    )
    return deadline.dt.tz_localize(config.market_timezone, ambiguous="NaT", nonexistent="shift_forward").dt.tz_convert("UTC")


def build_decisions(df: pd.DataFrame, config: BacktestConfig) -> pd.DataFrame:
    """One row per (location, operating day): features as of the deadline plus the realized target."""
    df = add_operating_day(df, config)
    lo, hi = config.delivery_hours
    n_hours = hi - lo

    delivery = df[(df["local_hour"] >= lo) & (df["local_hour"] < hi)]
    target = (
        delivery.groupby(["location", "operating_day"])["da_rt_spread"]
        .agg(target_dart_mean="mean", delivered_hours="count")
        .reset_index()
    )
    # Skip days with missing hours rather than trading a partial block.
    target = target[target["delivered_hours"] == n_hours].copy()
    target["decision_utc"] = decision_time_utc(target["operating_day"], config)
    target = target.dropna(subset=["decision_utc"]).sort_values("decision_utc")

    # Storm and outage features: latest row per location whose vintage precedes the deadline.
    storm = df[["location", "data_vintage"] + STORM_COLUMNS].dropna(subset=["data_vintage"])
    storm = storm.sort_values("data_vintage")
    out = pd.merge_asof(
        target, storm, left_on="decision_utc", right_on="data_vintage", by="location", direction="backward"
    )

    # Load error: trailing mean over the last N published intervals before the deadline.
    load = df[["location", "timestamp_utc", "load_error_mw"]].copy()
    load["available_utc"] = load["timestamp_utc"] + pd.Timedelta(hours=config.publication_lag_hours)
    load = load.sort_values(["location", "timestamp_utc"])
    load["trailing_load_error_mw"] = load.groupby("location")["load_error_mw"].transform(
        lambda s: s.rolling(config.load_error_lookback_hours, min_periods=config.load_error_lookback_hours).mean()
    )
    load = load.dropna(subset=["trailing_load_error_mw"]).sort_values("available_utc")
    out = pd.merge_asof(
        out.sort_values("decision_utc"),
        load[["location", "available_utc", "trailing_load_error_mw"]],
        left_on="decision_utc",
        right_on="available_utc",
        by="location",
        direction="backward",
    )
    return out.sort_values(["operating_day", "location"]).reset_index(drop=True)


# Standardization is fitted on the training period only and then applied to
# every period, so test-period data never shapes the signals.
Scaler = Dict[str, Tuple[float, float]]


def fit_scaler(train: pd.DataFrame, columns, fill: Dict[str, float]) -> Scaler:
    scaler: Scaler = {}
    for col in columns:
        s = train[col].fillna(fill.get(col, 0.0))
        sd = float(s.std(ddof=0))
        scaler[col] = (float(s.mean()), sd if np.isfinite(sd) and sd > 0 else 1.0)
    return scaler


def z(df: pd.DataFrame, col: str, scaler: Scaler, fill: float = 0.0) -> pd.Series:
    mean, sd = scaler[col]
    return (df[col].fillna(fill) - mean) / sd


FILL = {"storm_distance_mi": 999.0}
FEATURE_COLUMNS = STORM_COLUMNS + ["trailing_load_error_mw"]


def make_signals(df: pd.DataFrame, scaler: Scaler) -> pd.DataFrame:
    out = df.copy()
    zz = {col: z(out, col, scaler, FILL.get(col, 0.0)) for col in FEATURE_COLUMNS}
    storm_severity = 0.50 * zz["max_wind_mph"] + 0.20 * zz["hail_size_in"] - 0.30 * zz["storm_distance_mi"]
    physical_exposure = (
        0.40 * zz["outage_customers"] + 0.30 * zz["generation_outage_mw"] + 0.30 * zz["transmission_constraint"]
    )
    # Signal 1: storm-driven congestion/outage.
    out["signal_congestion"] = storm_severity + physical_exposure
    # Signal 2: load forecast error already observed before the deadline.
    out["signal_load_error"] = zz["trailing_load_error_mw"]
    # Signal 3: restoration-duration volatility proxy. A production model should
    # estimate duration from historical event-level restoration curves.
    out["signal_restoration_vol"] = zz["outage_customers"] + zz["max_wind_mph"] + zz["generation_outage_mw"]
    return out


def chronological_split(df: pd.DataFrame, train_frac: float = 0.60, valid_frac: float = 0.20):
    days = np.sort(df["operating_day"].dropna().unique())
    train_end = days[int(len(days) * train_frac)]
    valid_end = days[int(len(days) * (train_frac + valid_frac))]
    train = df[df["operating_day"] < train_end]
    valid = df[(df["operating_day"] >= train_end) & (df["operating_day"] < valid_end)]
    test = df[df["operating_day"] >= valid_end]
    return train, valid, test


def fit_threshold(train: pd.DataFrame, signal: str, quantile: float) -> float:
    return float(train[signal].quantile(quantile))


def choose_direction(valid: pd.DataFrame, signal: str, threshold: float, config: BacktestConfig) -> Optional[int]:
    """Long DART (+1) or short (-1) from the validation period, or None if too few events."""
    hits = valid[valid[signal] >= threshold]["target_dart_mean"].dropna()
    if len(hits) < config.min_validation_trades or hits.mean() == 0:
        return None
    return 1 if hits.mean() > 0 else -1


def paper_trade(
    df: pd.DataFrame,
    signal: str,
    threshold: float,
    direction: int,
    config: BacktestConfig,
) -> pd.DataFrame:
    """Fixed-notional paper P&L, one position per location and operating day.

    direction=+1 means long DART (buy day-ahead, sell real-time); -1 is short.
    Slippage is charged on both the day-ahead and real-time legs in $/MWh.
    Losses are not capped: a virtual position has no stop once the day-ahead
    market clears.
    """
    lo, hi = config.delivery_hours
    mwh = config.position_mw * (hi - lo)
    x = df[df[signal] >= threshold].copy()
    x["raw_pnl"] = direction * x["target_dart_mean"] * mwh
    x["cost"] = 2.0 * config.slippage_per_mwh * mwh
    x["net_pnl"] = x["raw_pnl"] - x["cost"]
    x["signal_name"] = signal
    x["direction"] = direction
    return x


def summarize(trades: pd.DataFrame) -> pd.Series:
    if trades.empty:
        return pd.Series({"trades": 0, "mean_net_pnl": np.nan, "median_net_pnl": np.nan, "hit_rate": np.nan,
                          "worst_trade": np.nan, "max_drawdown": np.nan, "total_net_pnl": 0.0})
    pnl = trades.sort_values("operating_day")["net_pnl"].astype(float)
    equity = pnl.cumsum()
    drawdown = equity - equity.cummax()
    return pd.Series({
        "trades": len(trades),
        "mean_net_pnl": pnl.mean(),
        "median_net_pnl": pnl.median(),
        "hit_rate": (pnl > 0).mean(),
        "worst_trade": pnl.min(),
        "max_drawdown": drawdown.min(),
        "total_net_pnl": pnl.sum(),
    })


SIGNALS = ["signal_congestion", "signal_load_error", "signal_restoration_vol"]


def evaluate(decisions: pd.DataFrame, config: BacktestConfig):
    """Fit on train, pick direction on validation, report on test only."""
    train, valid, test = chronological_split(decisions)
    scaler = fit_scaler(train, FEATURE_COLUMNS, FILL)
    train, valid, test = (make_signals(part, scaler) for part in (train, valid, test))

    results, trade_sets = [], {}
    for signal in SIGNALS:
        threshold = fit_threshold(train, signal, config.signal_quantile)
        direction = choose_direction(valid, signal, threshold, config)
        trades = paper_trade(test, signal, threshold, direction, config) if direction else test.iloc[0:0]
        summary = summarize(trades)
        summary["signal"] = signal
        summary["threshold"] = threshold
        summary["direction"] = direction if direction else 0
        results.append(summary)
        trade_sets[signal] = trades
    return pd.DataFrame(results), trade_sets


def run(path: str | Path, output_dir: str | Path = "storm_nodal_output", config: BacktestConfig = BacktestConfig()) -> pd.DataFrame:
    df = load_data(path)
    df = df[df["market"].eq(config.market)].copy()
    decisions = build_decisions(df, config)
    summary, trade_sets = evaluate(decisions, config)

    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    for signal, trades in trade_sets.items():
        trades.to_csv(output / f"{signal}_test_trades.csv", index=False)
    summary.to_csv(output / "summary.csv", index=False)
    print(summary.to_string(index=False))
    print(f"Saved results under {output.resolve()}")
    return summary


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("csv", help="Prepared historical CSV with the required columns")
    parser.add_argument("--output-dir", default="storm_nodal_output")
    parser.add_argument("--market", default="PJM")
    parser.add_argument("--timezone", default=None, help="Market clock, e.g. America/New_York or Etc/GMT+5")
    args = parser.parse_args()
    tz = args.timezone or ("Etc/GMT+5" if args.market == "MISO" else "America/New_York")
    run(args.csv, args.output_dir, BacktestConfig(market=args.market, market_timezone=tz))
