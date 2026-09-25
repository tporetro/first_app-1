# Power Marketing: How Traders Profit from Electricity Price Risk

Power marketing is the business of managing electricity, fuel, transmission and price risk across time and location. Traders profit when they forecast those relationships better than the market does, or when they control physical assets that can respond to price differences.

Electricity must be produced and consumed almost at the same moment. Storage is limited, demand depends heavily on time of day and weather, and transmission lines congest. Prices can therefore move from ordinary to extreme levels within minutes.

> Educational material with illustrative numbers, not investment advice. Wholesale power, futures and options involve leverage, illiquidity and margin calls, and losses can exceed the amount committed.

## Contents

1. [Market variables](#1-market-variables)
2. [How wholesale power is priced](#2-how-wholesale-power-is-priced)
3. [Why prices are volatile](#3-why-prices-are-volatile)
4. [Profit engines](#4-profit-engines)
5. [The analytical stack](#5-the-analytical-stack)
6. [Worked example: hedging a spark spread](#6-worked-example-hedging-a-spark-spread)
7. [Valuing plant flexibility with simulation](#7-valuing-plant-flexibility-with-simulation)
8. [Trade workflow and risk rules](#8-trade-workflow-and-risk-rules)
9. [References](#9-references)

---

## 1. Market variables

| Variable | What it covers |
|---|---|
| Time | Day-ahead vs. real-time; peak vs. off-peak; summer vs. winter |
| Location | Price at one node or zone vs. another |
| Fuel | Natural gas, coal, hydro, nuclear, wind and solar availability |
| Physical constraints | Transmission capacity, generator outages, ramp limits, fuel delivery |
| Demand | Weather-driven heating and cooling load, industrial load, data centers, unexpected events |
| Market rules | Bidding, dispatch, settlement, uplift, congestion, capacity and ancillary-service rules |

FERC describes the day-ahead market as a forward market that schedules resources for the next operating day. The real-time market adjusts dispatch continuously as demand, weather, outages and renewable output depart from forecast.

## 2. How wholesale power is priced

Most organized U.S. markets are run by an RTO or ISO: PJM, MISO, SPP, NYISO, ISO-NE, CAISO and ERCOT. ERCOT is overseen mainly by the Public Utility Commission of Texas rather than FERC, so FERC's rules and descriptions do not apply to it in full.

Generators submit offers, load-serving entities submit bids or schedules, and the operator dispatches resources subject to grid constraints. The result is a **locational marginal price (LMP)**:

```
LMP = energy component + loss component + congestion component
```

- **Energy:** cost of supplying the next MWh.
- **Loss:** cost of electricity lost in transmission.
- **Congestion:** cost of constrained transmission paths.

There is no single "electricity price". There are thousands of prices across nodes, zones and intervals. Every trade starts with the question: *which electricity, at which location, in which interval, under which settlement rule?*

## 3. Why prices are volatile

- **Demand shocks.** Heat drives air-conditioning load, and cold drives heating load where electric heat is common.
- **Supply outages.** Losing a large unit or transmission line when the system is near its limit can make the marginal price jump.
- **Gas prices and pipelines.** Gas units set the marginal price in many hours, so gas-price spikes and deliverability limits pass straight into power.
- **Renewable forecast error.** A wind shortfall forces the system onto more expensive gas units or reserves.
- **Congestion.** If cheap generation cannot reach load, the load pocket prices far above the source.
- **Limited storage and ramping.** Start times, minimum run times and ramp limits make prices nonlinear. A small change in conditions can force a much more expensive unit online.

EIA lists fuel costs, weather, demand, plant availability and transmission infrastructure as the main drivers of electricity prices.

## 4. Profit engines

### 4.1 Asset-backed generation optimization

A gas unit with power at $60/MWh, gas at $7/MMBtu, a 7 MMBtu/MWh heat rate and $5/MWh variable cost earns:

```
60 − (7 × 7) − 5 = $6/MWh
$6 × 100 MW × 4 h = $2,400
```

The owner decides whether to start, which hours to run, whether to sell day-ahead or wait for real time, whether to reserve gas, whether to offer energy or reserves, and how much to hedge forward. This is an optimization over fuel, start costs, minimum run times, ramp limits, outage risk and expected prices, not simply "buy low, sell high". Section 7 shows how to value it.

### 4.2 Spark-spread trading

```
Spark spread = P_power − (heat rate × P_gas)
$60 − (7 × $7) = $11/MWh  (before O&M and start costs)
```

A trader can profit by correctly anticipating changes in power relative to gas, heat rates, the marginal fuel mix, weather that moves power demand more than gas demand, or regional pipeline constraints. The trade can be expressed through generation, futures, swaps, options or combinations of them. The main risk is that the relationship breaks down, for example when a plant cannot get gas just as the spread looks best.

### 4.3 Day-ahead vs. real-time (DART)

This guide defines `DART = P_real-time − P_day-ahead`. Many desks and ISO reports use the opposite sign (DA − RT), so always state the convention.

A 100 MW position over 4 hours, with real time averaging $20/MWh above day-ahead:

```
100 × $20 × 4 = $8,000 gross
```

This figure is before fees, credit costs, losses, congestion and adverse hours. A view on DART can rest on weather revisions after the day-ahead close, expected outages, wind or solar forecast error, load forecasts that look too low, or historical patterns by hour and node. Some ISOs allow **virtual bids** (INCs and DECs) that settle day-ahead against real-time without physical delivery. The rules differ by ISO, and FERC's anti-manipulation rules apply.

### 4.4 Congestion and basis

Node A at $40 and Node B at $55 gives a $15/MWh spread. For 50 MW over 3 hours:

```
50 × $15 × 3 = $2,250 gross
```

Congestion is path-dependent. A line outage, generator outage, weather change or operator action can reverse the spread, and transmission upgrades can remove it for good. **Basis risk** is the risk that a hub hedge does not follow a specific node, and it is largest during stressed events.

### 4.5 Financial transmission rights (FTRs)

An FTR pays the day-ahead congestion difference between a source and a sink. It is a financial settlement instrument, not a right to use a line. FTRs are used both to hedge congestion costs and to speculate on congestion. The risks are outage and topology assumptions, loop flows, counter-flow, auction valuation errors and long-dated exposure to a changing grid.

### 4.6 Weather and load forecasting

Traders model temperature, degree days, humidity, wind, cloud cover, storms and ice, and how load responds to each. The edge is not "it will be hot". The edge is **how the weather will differ from what the day-ahead curve and forward prices already reflect**. A correct forecast still loses money if the market priced it in earlier.

### 4.7 Ancillary services and storage

Regulation, spinning and non-spinning reserve, voltage support, black start, fast frequency response and capacity products all have value. A battery or flexible resource earns option value by switching between energy and reserves as prices move. The risks are that the expected opportunity never comes, the asset is unavailable, or cycle limits cap profitable use.

### 4.8 Relative value

Common relative-value trades are DA vs. RT, peak vs. off-peak, month vs. month, hub vs. hub, node vs. node, power vs. gas, and implied volatility across products. Spreads reduce directional risk but do not remove it. Correlations tend to break during heat waves, polar vortices, pipeline failures and rule changes, which are exactly the events that matter most.

### 4.9 Options

| Structure | Use |
|---|---|
| Calls / puts | Benefit from higher / lower prices |
| Call and put spreads | Directional view with defined risk and capped payoff |
| Straddles and strangles | Long volatility |
| Short volatility | Collects premium, but can lose heavily in price spikes |
| Calendar-spread options | View on the difference between months |
| Cross-commodity options | Hedge or express power vs. gas views |

The question for any option trade is: **will the realized move, at this location and time, exceed what the option market has already priced?** Consider direction, magnitude, timing, implied volatility, skew, fuel correlation, liquidity, and what happens on exercise and assignment.

## 5. The analytical stack

**Fundamental data.** Hourly load forecasts, weather and forecast revisions, outages and planned maintenance, renewable forecasts, gas prices and pipeline constraints, coal, hydro and nuclear availability, transmission outages, emissions prices, reservoir levels, interchange, tariff changes, and historical nodal and hub prices. Align everything to the right interval and node. A monthly average is useless for an hourly congestion trade.

**Unit economics.** Heat rate, variable cost, start cost, minimum run time, ramp rate, minimum generation, forced outage rate, fuel deliverability and opportunity cost.

**Market microstructure.** Bid-ask spreads, depth, auction rules and deadlines, credit, collateral and margin, price caps and emergency rules, settlement conventions, position limits, and whether a product settles physically or financially.

**P&L attribution.**

```
P&L = price + volume + shape + basis + volatility + operational effects
```

A generator can lose money when average prices rise if it is offline in the high-price hours, gas rises more than power, its node underperforms the hub, it cannot ramp fast enough, or the spike falls outside its contracted delivery period.

## 6. Worked example: hedging a spark spread

A gas unit expects to produce **1,000 MWh**. The inputs are power at $60/MWh, gas at $3.50/MMBtu and a 7.0 MMBtu/MWh heat rate, so it burns 7,000 MMBtu.

### Step 1: Spark spread

```
Fuel cost     7.0 × $3.50        = $24.50/MWh
Gross spread  $60 − $24.50       = $35.50/MWh  →  $35,500
Net of $3 O&M $35.50 − $3.00     = $32.50/MWh  →  $32,500
```

This excludes fixed costs, start costs, emissions, transmission, uplift and imbalance charges. The scenario tables below use the gross figure.

### Step 2: Futures hedge

The generator is long power and short gas. To lock the margin it **sells 1,000 MWh of power** at $60 and **buys 7,000 MMBtu of gas** at $3.50, using the heat-rate ratio `gas volume = power volume × heat rate`. A standard CME Henry Hub contract is 10,000 MMBtu, so 7,000 MMBtu needs a smaller contract, an OTC swap or a partial hedge. The example assumes fractional sizes.

| Scenario | Physical | Power futures | Gas futures | Total |
|---|---:|---:|---:|---:|
| Power $60, gas $3.50 | $35,500 | $0 | $0 | **$35,500** |
| Power $75, gas $2.50 | $57,500 | −$15,000 | −$7,000 | **$35,500** |
| Power $45, gas $5.00 | $10,000 | +$15,000 | +$10,500 | **$35,500** |

### Step 3: Options hedge

The generator buys a **$55 power put** at $2/MWh ($2,000) and a **$4 gas call** at $0.20/MMBtu ($1,400), for a **$3,400** total premium.

| Scenario | Physical | Put payoff | Call payoff | Net of premium |
|---|---:|---:|---:|---:|
| Power $60, gas $3.50 | $35,500 | $0 | $0 | **$32,100** |
| Power $75, gas $2.50 | $57,500 | $0 | $0 | **$54,100** |
| Power $45, gas $5.00 | $10,000 | $10,000 | $7,000 | **$23,600** |

The options hedge has a hard **floor**. Power can't net less than the $55 strike, and gas can't cost more than the $4 strike:

```
1,000 × $55 − 7,000 × $4 − $3,400 = $23,600
```

Scenario C lands exactly on that floor.

### Comparison

| Scenario | Unhedged | Futures | Put + call |
|---|---:|---:|---:|
| Power $60, gas $3.50 | $35,500 | $35,500 | $32,100 |
| Power $75, gas $2.50 | $57,500 | $35,500 | $54,100 |
| Power $45, gas $5.00 | $10,000 | $35,500 | $23,600 |
| Power $250, gas $15, unit at 40% | $58,000 | **−$51,500** | $131,600 |

The last row is a stress case added to the original example. The unit trips during a cold snap and delivers only 400 MWh. The futures hedge is still short 1,000 MWh of power at $60, so it loses $190,000 on power. The gas leg earns back $80,500, but the total is a loss. The options hedge can't lose more than its premium, and here the gas call pays off heavily. This is **volume risk**, and it is why generators rarely hedge 100% of expected output with futures.

**Futures** lock the margin, give up upside, create daily margin calls, and still carry basis, shape, volume and operational risk. **Options** protect against large adverse moves, keep the upside and cost premium. They leave exposure between the strikes and bring volatility, liquidity and exercise risk.

### Speculating on the spread

A trader with no plant who expects the spread to **widen** buys power calls and gas puts in the heat-rate ratio. With a $60 call at $2 and a $3.50 put at $0.20 (premium $3,400), a move to power $75 and gas $2.50 pays:

```
1,000 × ($75 − $60) + 7,000 × ($3.50 − $2.50) − $3,400 = $18,600
```

The maximum loss on long options is the premium plus transaction costs. Note that at-the-money options usually cost more than the out-of-the-money hedge options, so reusing the $2 and $0.20 premiums flatters the trade. To bet on a **narrowing** spread, buy power puts and gas calls. Selling options cuts the premium but exposes the seller to large losses in power-price spikes.

### Collars

A **power collar** buys a $55 put and sells a $75 call. It keeps a floor near $55 and gives up upside above $75. A **gas collar** buys a $4 call and sells a $2.50 put. It caps gas cost near $4 and gives up savings below $2.50. Collars cut net premium, but the sold option is an obligation that needs margin. A collar is not free insurance.

### Four hedge ratios to verify

1. **Heat rate.** Use the plant's actual heat rate at its operating level, not a generic benchmark.
2. **Volume.** Use expected generation, not nameplate capacity.
3. **Time.** Match hourly vs. monthly, peak vs. off-peak, and DA vs. RT.
4. **Location.** Hedge power at the plant's node or nearest liquid hub, and gas at its delivery point. Henry Hub and local gas diverge when pipelines are constrained.

### Decision rule

- **Lock a known margin:** sell power futures and buy gas futures at the heat-rate ratio.
- **Protect the downside and keep the upside:** buy power puts and buy gas calls.
- **Bet on the spread widening:** buy power calls and buy gas puts.

The arithmetic is simple. The hard work is matching the hedge to the plant's real heat rate, hourly output, location, gas basis, contract size, settlement and liquidity.

## 7. Valuing plant flexibility with simulation

A spark-spread option on paper is only an approximation of a real plant. Start costs, minimum up and down times, ramp limits and outages make it path-dependent. The standard approach is Monte Carlo simulation with an optimized dispatch policy.

### 7.1 Procedure

```
Inputs: plant parameters, power and gas forward curves, price history,
        volatility and correlation parameters, discount curve, path count

Calibrate: power, gas, basis, outage and weather/load models

For each path m:
    Simulate hourly power, gas, load, renewables, congestion/basis, availability
    Initialize plant status, min up/down counters, fuel inventory, storage state
    For each decision hour t:
        Build the feasible actions given capacity, heat-rate curve, ramp limits,
        start costs, minimum run times, outages and reserve requirements
        Choose an action by dynamic programming, MIP dispatch, or regressed
        continuation value
        Record generation, fuel burn, starts/stops, power revenue, fuel cost,
        ancillary revenue, operating cash flow
    Discount the path's cash flows; store the value and decisions

Value = average over paths
Repeat for fixed, must-run and restricted-flexibility operation, and for
alternative plant specifications

Flexibility value = flexible valuation − restricted valuation
Then: confidence intervals, convergence tests, sensitivities, stress scenarios
```

### 7.2 Continuation-value step (Longstaff–Schwartz)

For a two-state (off/on) unit, the backward step regresses next-hour value on today's state variables `x` (for example power and gas prices at `t`):

```python
cont_if_off = discount * fit_predict(x, v[t + 1, 0])
cont_if_on  = discount * fit_predict(x, v[t + 1, 1])

start = operating_margin - plant.startup_cost + cont_if_on > cont_if_off
stay  = operating_margin + cont_if_on > cont_if_off

# Use the regression only to choose the action. Carry realized
# path values backward, not fitted values.
v[t, 0] = np.where(start,
                   operating_margin - plant.startup_cost + discount * v[t + 1, 1],
                   discount * v[t + 1, 0])
v[t, 1] = np.where(stay,
                   operating_margin + discount * v[t + 1, 1],
                   discount * v[t + 1, 0])
```

Why this differs from setting `v[t] = np.maximum(...)` of the fitted values:

- **Bias.** Taking the maximum of noisy regression estimates adds an upward bias at each step, and it compounds backward through thousands of hours. Standard Longstaff–Schwartz uses the fit only for the decision and keeps realized cash flows.
- **Out-of-sample pricing.** Estimate the policy on one set of paths and value it on a fresh set. The result is then a lower bound, because any feasible policy is. Pair it with a dual (upper-bound) estimate if the gap matters.
- **Minimum up/down times.** A two-state `{off, on}` model can't enforce them. Extend the state to `(status, hours in status)`, or model min-run as committed blocks.
- **Operating margin.** Set it to the best feasible output level given the heat-rate curve: `max over q in [q_min, q_max] of q·P − fuel(q)·G − VOM·q`. When prices are below cost, "stay on" should still earn the (negative) margin at minimum generation, not zero.
- **Shutdown cost.** If stopping has a cost, subtract it from `value_on_stop`.

### 7.3 Pitfalls in the full valuation

- **Foresight bias.** A MIP that sees the whole simulated path dispatches with perfect foresight and overstates value. Use rolling-horizon or regression-based decisions.
- **Common random numbers.** Value the flexible and restricted cases on the same paths. Otherwise the flexibility value, a difference of two large numbers, is swamped by noise.
- **Measure.** For valuation and hedging, calibrate prices to forward curves. Historical (physical-measure) dynamics are for risk and scenarios, not for pricing.
- **Joint tails.** Spikes, gas squeezes and forced outages are correlated in cold weather. Simulating them independently understates losses on short-power hedges. The trip row in section 6 shows how large that loss can be.

## 8. Trade workflow and risk rules

1. **Choose the market and location:** ISO, node or hub, delivery date and hours.
2. **Identify the physical driver:** heat wave, outage, gas constraint, low wind or congestion.
3. **Estimate the market impact:** changes in load, generation, congestion and the marginal fuel.
4. **Compare with the market:** check whether day-ahead prices, forwards, spreads or implied volatility already reflect it.
5. **Choose the least-risky expression:** spread, FTR, virtual, future, option spread or dispatch decision.
6. **Stress-test:** forecast misses, generator and transmission outages, gas shocks, spread reversals, thin liquidity and higher margin.
7. **Set limits:** maximum loss, exposure by location and hour, liquidity limits and forced-reduction triggers.
8. **Reconcile after settlement:** separate forecast, execution, volume, basis and operational error. A profitable trade may have been lucky, and a losing one may have followed a sound process.

Volatility is not an edge in itself. Real edges come from physical optionality (plants, storage, demand response), better information, better models, better execution, the capacity to hold through adverse moves, and knowledge of local rules. A trader can be right on direction and still lose because the position was too large, the move came after expiry, the location hedge failed, the asset was down, the market gapped, collateral calls rose, or the model missed a nonlinear constraint.

**Bottom line.** Power marketers profit through optimization and relative value, not by guessing the direction of prices. The core skill is turning physical knowledge into a risk-controlled financial position. The core danger is that the constraints that create the opportunities can also create losses far larger than ordinary price models predict.

## 9. References

1. FERC, [Energy Markets](https://www.ferc.gov/understanding-energy-markets)
2. EIA, [Factors Affecting Electricity Prices](https://www.eia.gov/energyexplained/electricity/prices-and-factors-affecting-prices.php)
3. Harvard Electricity Policy Group, [Virtual Bidding and Electricity Market Design](https://hepg.hks.harvard.edu/publications/virtual-bidding-and-electricity-market-design)
4. ISO New England, [Financial Transmission Rights](https://www.iso-ne.com/markets-operations/settlements/understand-bill/item-descriptions/ftr)
5. EIA, [An Introduction to Spark Spreads](https://www.eia.gov/todayinenergy/detail.php?id=9911)
6. FERC, [Prohibition of Energy Market Manipulation](https://www.ferc.gov/enforcement-legal/enforcement/prohibition-energy-market-manipulation)
7. CME Group, Henry Hub Natural Gas Futures contract specifications
8. CME Group, *Fundamentals of Options on Futures*
9. Longstaff, F. and Schwartz, E. (2001), "Valuing American Options by Simulation: A Simple Least-Squares Approach", *Review of Financial Studies* 14(1)
