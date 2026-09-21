# FastAPI Webhook Backend

Implements the 3 endpoints specified in `03-n8n/fastapi_webhook_contract.md`. This is what runs at `api.restorationgc.net` in the architecture diagram.

## Endpoints

- **`POST /webhooks/storm-alert`** — HMAC-verified (`X-RGC-Signature`). Validates the storm-event payload, then forwards it as-is to n8n's W1 webhook (`N8N_STORM_ALERT_WEBHOOK_URL`) and relays W1's response. If `N8N_STORM_ALERT_WEBHOOK_URL` isn't set, it validates and returns `{"status": "validated_only", ...}` without forwarding — useful for standing this service up and testing it before n8n is wired in.
- **`GET /approve`** — the one-tap link from the W6 daily digest email (`?token=<uuid>&d=approve|edit|reject`). Looks up the `approval_queue` row by `one_tap_token`, and is idempotent: if a decision is already recorded, it reports that back rather than overwriting it. Returns a small HTML confirmation page since it's meant to be opened from an email link, not called programmatically.
- **`POST /webhooks/retell-status`** — HMAC-verified. Logs a completed voice call as an `attribution_events` row (`event_name = voice_connect`), but only when `consent_verified` AND `ai_disclosed` are both true — a bad or misconfigured Retell payload can't backdoor a voice touch into attribution without the same consent/disclosure gate W4 and the `chk_consent_disclosure` DB constraint already enforce.
- **`GET /healthz`** — plain liveness check for whatever's running this (uptime monitor, container orchestrator).

## Environment Variables

| Var | Required | Notes |
|---|---|---|
| `FASTAPI_HMAC_SECRET` | Yes | Shared secret for verifying `X-RGC-Signature` on both webhook POSTs. Must match whatever your storm-data provider and Retell are configured to sign with. |
| `SUPABASE_URL` | Yes | e.g. `https://bccpaguzuowwgokxgsjh.supabase.co` |
| `SUPABASE_SERVICE_KEY` | Yes | `service_role` key — bypasses RLS. Keep this server-side only, same rule as everywhere else in this build. |
| `N8N_STORM_ALERT_WEBHOOK_URL` | No | Full URL to n8n's W1 webhook. Omit to run this service standalone before n8n is set up. |

Talks to Supabase via its REST API (PostgREST) with the service-role key, not a direct Postgres connection — the only runtime dependency beyond FastAPI itself is `httpx`.

## Run Locally

```
pip install -r requirements.txt
export FASTAPI_HMAC_SECRET=... SUPABASE_URL=... SUPABASE_SERVICE_KEY=...
uvicorn main:app --reload
```

## Test

```
pip install -r requirements.txt pytest respx
pytest test_main.py -v
```

14 tests cover: HMAC verification (missing/invalid/valid signature) on both webhook endpoints, payload validation, forwarding to n8n plus the downstream-unreachable case, `/approve`'s unknown-token/success/already-decided/bad-decision-value paths, and the retell-status consent/disclosure gate. All were run against this exact code before it was committed — not just read over.

## Deploying

Any ASGI host works (this build was written generically, not tied to a specific PaaS): Railway, Fly.io, a container behind your own reverse proxy, etc. Point your storm-data provider's webhook and Retell's status-callback webhook at this service's `/webhooks/*` URLs, each configured to sign requests with `FASTAPI_HMAC_SECRET`. This session has no hosting/deploy connector attached, so provisioning wherever you run this is on you — the code and tests are the deliverable here.
