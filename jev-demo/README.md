# Jev demo (Vercel AI Gateway)

A small local script that asks the `typesafe-ai/jev` evaluation model a yes/no question
through Vercel AI Gateway, using `experimental_evaluate` from the `ai` package (v7).
It prints the probability that a refund was issued, the total elapsed time
(including the network round trip), and the cost if the gateway reports it.

## Setup (once)

1. Use Node.js 22.18 or newer (`node --version`).
2. `npm install`
3. `cp .env.example .env`, then paste your key after `AI_GATEWAY_API_KEY=`.
   `.env` is ignored by Git. Never commit it or put the key in client-side code.
   Create a key under Vercel dashboard → AI Gateway → API Keys. Give it a small spend
   limit and an expiration date. Vercel may ask for a credit card before requests work.

## Run

```sh
node --env-file=.env index.mjs
```

To try a different state, pass it as an argument:

```sh
node --env-file=.env index.mjs "The customer requested a refund, but the agent has not processed it."
```

## Measured results (2026-09-26)

Real output from `index.mjs` via Vercel AI Gateway. Elapsed time is measured by the
script and includes the network round trip. Cost is what the gateway reported.

| State | Probability a refund was issued | Elapsed | Cost (USD) |
|---|---|---|---|
| The support agent issued a full refund to the customer. | 0.99 | 910 ms | $0.000011844 |
| The customer requested a refund, but the agent has not processed it. | 0.04 | 741 ms | $0.00001197 |

If you see `GatewayRateLimitError: The upstream provider is currently experiencing high demand`,
wait a minute and rerun. It happened often during testing and failed calls were not billed.
