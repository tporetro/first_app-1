# Ruby on Rails Tutorial: first application

This is the first application for the
[*Ruby on Rails Tutorial*](http://railstutorial.org/)
by [Michael Hartl](http://michaelhartl.com/).

## Spark spread hedge calculator

`/spark_spread` compares a gas plant's margin unhedged, hedged with
futures, and hedged with power puts plus gas calls. The math lives in
`app/models/spark_spread_hedge.rb`; its tests run without Rails:

    ruby test/models/spark_spread_hedge_test.rb

Background and the worked example are in
[docs/power_marketing_guide.md](docs/power_marketing_guide.md).
