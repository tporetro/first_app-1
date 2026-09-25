"""Tests for storm_nodal_backtest. Run with: python -m pytest stormsignal"""

from datetime import time

import numpy as np
import pandas as pd
import pytest

import storm_nodal_backtest as bt

CONFIG = bt.BacktestConfig(market="MISO", market_timezone="Etc/GMT+5", min_validation_trades=3)


def synthetic(days=60, locations=("A", "B"), seed=0):
    """Hourly rows; timestamp_utc is interval ending. Storm fields known 2h after the interval."""
    rng = np.random.default_rng(seed)
    start = pd.Timestamp("2025-01-01 06:00", tz="UTC")  # HE1 of Jan 1 in EST
    rows = []
    for loc in locations:
        for h in range(days * 24):
            ts = start + pd.Timedelta(hours=h)
            da = 30 + rng.normal()
            rows.append({
                "timestamp_utc": ts, "market": "MISO", "location": loc,
                "da_lmp": da, "rt_lmp": da + rng.normal(scale=5),
                "load_forecast_mw": 1000.0, "load_actual_mw": 1000 + rng.normal(scale=20),
                "storm_id": "", "max_wind_mph": rng.uniform(0, 60), "hail_size_in": 0.0,
                "storm_distance_mi": rng.uniform(0, 300), "outage_customers": rng.uniform(0, 1000),
                "generation_outage_mw": rng.uniform(0, 200), "transmission_constraint": rng.uniform(0, 1),
                "data_vintage": ts + pd.Timedelta(hours=2),
            })
    return pd.DataFrame(rows)


def decisions(df):
    """Derive spread and load error the way load_data does, then build decisions."""
    df = df.assign(da_rt_spread=df["rt_lmp"] - df["da_lmp"],
                   load_error_mw=df["load_actual_mw"] - df["load_forecast_mw"])
    return bt.build_decisions(df, CONFIG)


def test_one_decision_per_location_and_day():
    d = decisions(synthetic(days=10))
    assert not d.duplicated(["location", "operating_day"]).any()
    assert (d["delivered_hours"] == 24).all()
    assert len(d) == 2 * 10


def test_operating_day_uses_market_clock():
    df = bt.add_operating_day(synthetic(days=1), CONFIG)
    first = df.iloc[0]
    assert first["operating_day"] == pd.Timestamp("2025-01-01") and first["local_hour"] == 0


def test_decision_is_previous_day_deadline_including_dst():
    days = pd.Series(pd.to_datetime(["2025-01-15", "2025-07-15"]))
    et = bt.BacktestConfig(market_timezone="America/New_York", da_deadline_local=time(10, 30))
    got = bt.decision_time_utc(days, et)
    assert got.iloc[0] == pd.Timestamp("2025-01-14 15:30", tz="UTC")  # EST
    assert got.iloc[1] == pd.Timestamp("2025-07-14 14:30", tz="UTC")  # EDT


def test_features_ignore_data_published_after_the_deadline():
    base = synthetic(days=20)
    d1 = decisions(base)
    changed = base.copy()
    # Rewrite everything from the operating day of the 15th onward, and the last
    # few hours before its deadline (still unpublished at 15:30 UTC on the 14th).
    cutoff = pd.Timestamp("2025-01-14 15:30", tz="UTC")
    late = changed["timestamp_utc"] + pd.Timedelta(hours=CONFIG.publication_lag_hours) > cutoff
    changed.loc[late, "load_actual_mw"] = 99_999.0
    changed.loc[changed["data_vintage"] > cutoff, "max_wind_mph"] = 999.0
    d2 = decisions(changed)
    day = pd.Timestamp("2025-01-15")
    cols = ["trailing_load_error_mw", "max_wind_mph"]
    pd.testing.assert_frame_equal(
        d1[d1["operating_day"] == day][cols].reset_index(drop=True),
        d2[d2["operating_day"] == day][cols].reset_index(drop=True),
    )


def test_scaler_is_fit_on_training_data_only():
    d = decisions(synthetic(days=40))
    train, _, test = bt.chronological_split(d)
    assert set(train["operating_day"]).isdisjoint(set(test["operating_day"]))
    d.loc[d.index.isin(test.index), "max_wind_mph"] += 1000  # extreme test-period storms
    train_after, _, _ = bt.chronological_split(d)
    mean, _ = bt.fit_scaler(train_after, bt.FEATURE_COLUMNS, bt.FILL)["max_wind_mph"]
    assert mean == pytest.approx(train["max_wind_mph"].fillna(0.0).mean())


def test_features_do_change_when_published_data_changes():
    base = synthetic(days=20)
    changed = base.copy()
    changed.loc[changed["timestamp_utc"] < pd.Timestamp("2025-01-14 12:00", tz="UTC"), "load_actual_mw"] += 500
    day = pd.Timestamp("2025-01-15")
    before = decisions(base).query("operating_day == @day")["trailing_load_error_mw"]
    after = decisions(changed).query("operating_day == @day")["trailing_load_error_mw"]
    assert (after.values - before.values > 0).all()


def test_direction_comes_from_validation_and_losses_are_not_capped():
    valid = pd.DataFrame({"sig": [1.0] * 5, "target_dart_mean": [-3.0] * 5})
    assert bt.choose_direction(valid, "sig", 0.5, CONFIG) == -1
    assert bt.choose_direction(valid.head(2), "sig", 0.5, CONFIG) is None

    test = pd.DataFrame({"sig": [1.0], "target_dart_mean": [-5_000.0], "operating_day": [pd.Timestamp("2025-01-01")]})
    trades = bt.paper_trade(test, "sig", 0.5, +1, CONFIG)
    # 1 MW x 24 h x -5,000 minus 2 x $1 x 24 MWh slippage.
    assert trades["net_pnl"].iloc[0] == pytest.approx(-120_048.0)


def test_run_end_to_end(tmp_path):
    csv = tmp_path / "data.csv"
    synthetic(days=60).to_csv(csv, index=False)
    summary = bt.run(csv, tmp_path / "out", CONFIG)
    assert set(summary["signal"]) == set(bt.SIGNALS)
    assert (tmp_path / "out" / "summary.csv").exists()
