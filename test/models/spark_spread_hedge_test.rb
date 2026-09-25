require 'minitest/autorun'
require File.expand_path('../../../app/models/spark_spread_hedge', __FILE__)

# Figures from the 1,000 MWh worked example: power $60, gas $3.50,
# heat rate 7.0, $55 power put at $2, $4 gas call at $0.20.
class SparkSpreadHedgeTest < Minitest::Test
  def setup
    @hedge = SparkSpreadHedge.new
  end

  def test_spark_spread_and_locked_margin
    assert_in_delta 7_000, @hedge.gas_volume_mmbtu
    assert_in_delta 35.50, @hedge.spark_spread
    assert_in_delta 35_500, @hedge.locked_margin
  end

  def test_locked_margin_net_of_vom
    assert_in_delta 32_500, SparkSpreadHedge.new(vom: 3).locked_margin
  end

  def test_premium
    assert_in_delta 3_400, @hedge.premium
  end

  def test_unhedged_scenarios
    assert_in_delta 35_500, @hedge.unhedged(60, 3.5)
    assert_in_delta 57_500, @hedge.unhedged(75, 2.5)
    assert_in_delta 10_000, @hedge.unhedged(45, 5)
  end

  def test_futures_hedge_locks_margin_at_full_output
    [[60, 3.5], [75, 2.5], [45, 5]].each do |power, gas|
      assert_in_delta 35_500, @hedge.futures_hedged(power, gas)
    end
  end

  def test_options_scenarios
    assert_in_delta 32_100, @hedge.options_hedged(60, 3.5)
    assert_in_delta 54_100, @hedge.options_hedged(75, 2.5)
    assert_in_delta 23_600, @hedge.options_hedged(45, 5)
  end

  def test_options_floor_matches_worst_case
    assert_in_delta 23_600, @hedge.options_floor
    assert_in_delta 23_600, @hedge.options_hedged(10, 20)
  end

  def test_futures_hedge_loses_when_unit_trips_in_a_spike
    # 400 MWh produced; hedges still sized to 1,000 MWh.
    assert_in_delta 58_000, @hedge.unhedged(250, 15, 40)
    assert_in_delta(-51_500, @hedge.futures_hedged(250, 15, 40))
    assert_in_delta 131_600, @hedge.options_hedged(250, 15, 40)
  end

  def test_blank_params_fall_back_to_defaults
    hedge = SparkSpreadHedge.new("heat_rate" => "", "power_futures" => "70")
    assert_in_delta 7.0, hedge.heat_rate
    assert_in_delta 70.0, hedge.power_futures
  end

  def test_rejects_bad_inputs
    assert_raises(ArgumentError) { SparkSpreadHedge.new(heat_rate: 0) }
    assert_raises(ArgumentError) { SparkSpreadHedge.new(volume_mwh: -1) }
    assert_raises(ArgumentError) { SparkSpreadHedge.new(power_futures: "abc") }
  end
end
