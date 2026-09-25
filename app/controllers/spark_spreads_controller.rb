class SparkSpreadsController < ApplicationController
  def show
    @hedge = SparkSpreadHedge.new(hedge_params)
    @results = scenarios.map { |scenario| @hedge.evaluate(scenario) }
  rescue ArgumentError => e
    flash.now[:error] = "Check the inputs: #{e.message}."
    @hedge = SparkSpreadHedge.new
    @results = SparkSpreadHedge::WORKED_EXAMPLE_SCENARIOS.map { |s| @hedge.evaluate(s) }
  end

  private

    def hedge_params
      params.slice(*SparkSpreadHedge::DEFAULTS.keys.map(&:to_s))
    end

    # The worked-example scenarios plus an optional custom one.
    def scenarios
      list = SparkSpreadHedge::WORKED_EXAMPLE_SCENARIOS.dup
      if params[:scenario_power].present? && params[:scenario_gas].present?
        output = params[:scenario_output].present? ? Float(params[:scenario_output]) : 100.0
        list << SparkSpreadHedge::Scenario.new("Custom",
                                               Float(params[:scenario_power]),
                                               Float(params[:scenario_gas]),
                                               output)
      end
      list
    end
end
