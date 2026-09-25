"""Storm-informed nodal power research scaffold.

This module does not download or fabricate data. It expects a prepared CSV with
market, weather, storm, and outage features. It creates three transparent
signals corresponding to:
  1) storm-driven congestion/outage;
  2) weather-to-load forecast error;
  3) restoration-duration volatility.

Use only observations whose data_vintage was available before timestamp_utc.
The output is a paper-research event study, not an execution system.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

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


@dataclass(frozen=True)
class BacktestConfig:
    market: str = "PJM"
    holding_hours: int = 6
    signal_quantile: float = 0.80
    slippage_per_mwh: float = 1.00
    position_mw: float = 1.0
    max_event_loss: float = 10_000.0


def load_data(path: str | Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    missing = sorted(REQUIRED_COLUMNS - set(df.columns))
    if missing:
        raise ValueError(f"Missing required columns: {missing}")

    df["timestamp_utc"] = pd.to_datetime(df["timestamp_utc"], utc=True)
    df["data_vintage"] = pd.to_datetime(df["data_vintage"], utc=True)
    df = df.sort_values(["location", "timestamp_utc"]).reset_index(drop=True)

    # Prevent look-ahead from revised data. A row is usable only if its vintage
    # timestamp predates the market interval being forecast.
    df = df[df["data_vintage"] <= df["timestamp_utc"]].copy()
    df["da_rt_spread"] = df["rt_lmp"] - df["da_lmp"]
    df["load_error_mw"] = df["load_actual_mw"] - df["load_forecast_mw"]
    df["abs_dart"] = df["da_rt_spread"].abs()
    return df


def standardize(s: pd.Series) -> pd.Series:
    sd = s.std(ddof=0)
    if not np.isfinite(sd) or sd == 0:
        return pd.Series(0.0, index=s.index)
    return (s - s.mean()) / sd


def add_storm_features(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out["storm_severity"] = (
        0.50 * standardize(out["max_wind_mph"].fillna(0.0))
        + 0.20 * standardize(out["hail_size_in"].fillna(0.0))
        - 0.30 * standardize(out["storm_distance_mi"].fillna(999.0))
    )
    out["physical_exposure"] = (
        0.40 * standardize(out["outage_customers"].fillna(0.0))
        + 0.30 * standardize(out["generation_outage_mw"].fillna(0.0))
        + 0.30 * standardize(out["transmission_constraint"].fillna(0.0))
    )
    out["storm_impact_score"] = out["storm_severity"] + out["physical_exposure"]
    return out


def add_forward_targets(df: pd.DataFrame, holding_hours: int) -> pd.DataFrame:
    out = df.copy()
    group = out.groupby("location", group_keys=False)
    out["future_dart_mean"] = group["da_rt_spread"].transform(
        lambda s: s.shift(-1).rolling(holding_hours, min_periods=holding_hours).mean().shift(-(holding_hours - 1))
    )
    out["future_abs_dart_mean"] = group["abs_dart"].transform(
        lambda s: s.shift(-1).rolling(holding_hours, min_periods=holding_hours).mean().shift(-(holding_hours - 1))
    )
    out["future_max_abs_dart"] = group["abs_dart"].transform(
        lambda s: s.shift(-1).rolling(holding_hours, min_periods=holding_hours).max().shift(-(holding_hours - 1))
    )
    return out


def make_signals(df: pd.DataFrame, config: BacktestConfig) -> pd.DataFrame:
    out = add_storm_features(df)
    out = add_forward_targets(out, config.holding_hours)

    # Signal 1: storm-driven congestion/outage. Direction is deliberately
    # expressed as a research feature; direction must be calibrated per node.
    out["signal_congestion"] = out["storm_impact_score"]

    # Signal 2: load forecast error. Positive forecast error predicts higher
    # real-time relative to day-ahead only if validated out of sample.
    out["signal_load_error"] = standardize(out["load_error_mw"].fillna(0.0))

    # Signal 3: restoration-duration volatility proxy. Here outage severity is
    # used as a pre-trade proxy; a production model should estimate duration
    # from historical event-level restoration curves.
    out["signal_restoration_vol"] = (
        standardize(out["outage_customers"].fillna(0.0))
        + standardize(out["max_wind_mph"].fillna(0.0))
        + standardize(out["generation_outage_mw"].fillna(0.0))
    )
    return out


def chronological_split(df: pd.DataFrame, train_frac: float = 0.60, valid_frac: float = 0.20):
    dates = np.sort(df["timestamp_utc"].dropna().unique())
    train_end = dates[int(len(dates) * train_frac)]
    valid_end = dates[int(len(dates) * (train_frac + valid_frac))]
    train = df[df["timestamp_utc"] < train_end]
    valid = df[(df["timestamp_utc"] >= train_end) & (df["timestamp_utc"] < valid_end)]
    test = df[df["timestamp_utc"] >= valid_end]
    return train, valid, test


def fit_threshold(train: pd.DataFrame, signal: str, quantile: float) -> float:
    return float(train[signal].quantile(quantile))


def paper_trade(
    df: pd.DataFrame,
    signal: str,
    threshold: float,
    direction: int,
    config: BacktestConfig,
) -> pd.DataFrame:
    """Create a simple fixed-notional paper P&L table.

    direction=+1 means long future DART; direction=-1 means short future DART.
    This is a synthetic research proxy, not a claim that the exact spread is
    executable. Slippage is charged on both entry and exit in $/MWh terms.
    """
    x = df[df[signal] >= threshold].copy()
    x["raw_pnl"] = direction * x["future_dart_mean"] * config.position_mw * config.holding_hours
    x["cost"] = 2.0 * config.slippage_per_mwh * config.position_mw * config.holding_hours
    x["net_pnl"] = x["raw_pnl"] - x["cost"]
    x["capped_pnl"] = x["net_pnl"].clip(lower=-config.max_event_loss, upper=config.max_event_loss)
    x["signal_name"] = signal
    x["direction"] = direction
    return x


def summarize(trades: pd.DataFrame) -> pd.Series:
    if trades.empty:
        return pd.Series({"trades": 0, "mean_net_pnl": np.nan, "median_net_pnl": np.nan, "hit_rate": np.nan, "max_drawdown": np.nan})
    pnl = trades["capped_pnl"].astype(float)
    equity = pnl.cumsum()
    drawdown = equity - equity.cummax()
    return pd.Series({
        "trades": len(trades),
        "mean_net_pnl": pnl.mean(),
        "median_net_pnl": pnl.median(),
        "hit_rate": (pnl > 0).mean(),
        "max_drawdown": drawdown.min(),
        "total_net_pnl": pnl.sum(),
    })


def run(path: str | Path, output_dir: str | Path = "storm_nodal_output") -> None:
    config = BacktestConfig()
    df = load_data(path)
    df = df[df["market"].eq(config.market)].copy()
    df = make_signals(df, config)
    train, valid, test = chronological_split(df)

    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)

    results = []
    specs = [
        ("signal_congestion", +1),
        ("signal_load_error", +1),
        ("signal_restoration_vol", +1),
    ]
    for signal, direction in specs:
        threshold = fit_threshold(train, signal, config.signal_quantile)
        trades = paper_trade(test, signal, threshold, direction, config)
        summary = summarize(trades)
        summary["signal"] = signal
        summary["threshold"] = threshold
        results.append(summary)
        trades.to_csv(output / f"{signal}_test_trades.csv", index=False)

    pd.DataFrame(results).to_csv(output / "summary.csv", index=False)
    print(pd.DataFrame(results).to_string(index=False))
    print(f"Saved results under {output.resolve()}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("csv", help="Prepared historical CSV with the required columns")
    parser.add_argument("--output-dir", default="storm_nodal_output")
    args = parser.parse_args()
    run(args.csv, args.output_dir)
