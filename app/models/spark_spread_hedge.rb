# Margin of a gas-fired generator under three hedging choices:
# unhedged, futures (sell power, buy gas at the heat-rate ratio),
# and options (buy power puts, buy gas calls).
#
# Hedges are sized to the expected output. A scenario's output_pct
# scales only the physical position, which shows volume risk.
class SparkSpreadHedge
  DEFAULTS = {
    volume_mwh:        1000.0,
    heat_rate:         7.0,
    vom:               0.0,
    power_futures:     60.0,
    gas_futures:       3.5,
    put_strike:        55.0,
    put_premium:       2.0,
    call_strike:       4.0,
    call_premium:      0.2
  }

  Scenario = Struct.new(:name, :power, :gas, :output_pct)

  WORKED_EXAMPLE_SCENARIOS = [
    Scenario.new("Prices unchanged",   60.0, 3.5, 100.0),
    Scenario.new("Power up, gas down", 75.0, 2.5, 100.0),
    Scenario.new("Power down, gas up", 45.0, 5.0, 100.0),
    Scenario.new("Cold snap, unit trips", 250.0, 15.0, 40.0)
  ]

  attr_reader(*DEFAULTS.keys)

  def initialize(attrs = {})
    DEFAULTS.each do |key, default|
      value = attrs[key] || attrs[key.to_s]
      value = default if value.nil? || value.to_s.strip.empty?
      instance_variable_set("@#{key}", Float(value))
    end
    raise ArgumentError, "heat_rate must be positive" unless heat_rate > 0
    raise ArgumentError, "volume_mwh cannot be negative" if volume_mwh < 0
  end

  def gas_volume_mmbtu
    volume_mwh * heat_rate
  end

  # $/MWh at the futures prices, before O&M.
  def spark_spread
    power_futures - heat_rate * gas_futures
  end

  def locked_margin
    volume_mwh * (spark_spread - vom)
  end

  def premium
    volume_mwh * put_premium + gas_volume_mmbtu * call_premium
  end

  # Worst case for the options hedge at full output: power at or below
  # the put strike and gas at or above the call strike.
  def options_floor
    volume_mwh * (put_strike - vom) - gas_volume_mmbtu * call_strike - premium
  end

  def unhedged(power, gas, output_pct = 100.0)
    mwh = volume_mwh * output_pct / 100.0
    mwh * (power - heat_rate * gas - vom)
  end

  def futures_hedged(power, gas, output_pct = 100.0)
    unhedged(power, gas, output_pct) +
      volume_mwh * (power_futures - power) +
      gas_volume_mmbtu * (gas - gas_futures)
  end

  def options_hedged(power, gas, output_pct = 100.0)
    unhedged(power, gas, output_pct) +
      volume_mwh * [put_strike - power, 0].max +
      gas_volume_mmbtu * [gas - call_strike, 0].max -
      premium
  end

  def evaluate(scenario)
    {
      scenario: scenario,
      unhedged: unhedged(scenario.power, scenario.gas, scenario.output_pct),
      futures:  futures_hedged(scenario.power, scenario.gas, scenario.output_pct),
      options:  options_hedged(scenario.power, scenario.gas, scenario.output_pct)
    }
  end
end
