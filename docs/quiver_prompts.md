# Quiver + Claude prompt library

Connect Quiver Quantitative (API key from the Quiver dashboard, Hobbyist plan ~ $30/mo)
to Claude, then run these. Insider filings are near-live (about 2 business days);
congressional filings lag (median ~28 days), so use them for research, not alerts.

## Insiders
- Are <TICKER> insiders buying or selling right now?
- Show me the most recent insider trades in the Quiver data.
- Using Quiver insider trading data, find every company where three or more different
  insiders made open market purchases in the last 60 days. Exclude option exercises and
  sales. Rank by number of distinct buyers, then total dollar value. Show each insider's
  name and title. Flag anything that looks like a batch (similar sizes, same filing date,
  e.g. a compensation plan) so I can find the real outliers.

## Congress, contracts, lobbying
- Show me the most recent congressional trades that have been filed.
- Give me the full political exposure on <TICKER>: congressional trades, contracts, and lobbying spend.
- Show me the individual lobbying line items for <TICKER> with the specific issue text.

## Combined
- Give me the full picture on <TICKER>: insider sentiment by quarter, institutional ownership, and top holders.
- From congressional and insider data of the last 90 days, show tickers that fewer than five
  distinct people traded, where activity is increasing, versus tickers that are already
  crowded. Explain what data you used to decide "increasing".
- Which of these should I watch most, and which lean most bullish? Rank by signal quality.

## Caveats
Insider selling can be pre-IPO cash-out or vesting; insider buying can be compensation
plans. Check sizes and filing dates. This is research, not financial advice.
