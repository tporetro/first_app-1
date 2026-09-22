# FastAPI Webhook Contract — api.restorationgc.net

**Implemented** in `10-fastapi/main.py` (with 14 passing tests in `10-fastapi/test_main.py`) — this document is the contract it implements; see `10-fastapi/README.md` for env vars and deploy notes.

```
POST /webhooks/storm-alert     (HMAC header X-RGC-Signature = hex(hmac_sha256(secret, raw_body)))
  body: {event_id, event_type, event_ts(ISO8601), max_hail_size_in, max_wind_mph, state, swath_geojson?, properties:[{parcel_id,address,geom_geojson,roof_sqft}]}
  resp 200: {status:"queued", draft:<uuid>}

GET  /approve?token=<uuid>&d=approve|edit|reject   (one-tap; writes approval_queue.decision, decision_ts)

POST /webhooks/retell-status   {call_id, owner_id, outcome, consent_verified:bool, ai_disclosed:bool}

GET  /webhooks/linkedin?challengeCode=...   (LinkedIn Community Management API validation handshake)
  resp 200: {challengeCode, challengeResponse: hex(hmac_sha256(LINKEDIN_CLIENT_SECRET, challengeCode))}
```

All endpoints reject with `401` if the signature is invalid, and log to `consent_records`/`attribution_events` as applicable.

## Storm-Data Source for `/webhooks/storm-alert`

The `storm-alert` payload can be produced from any of the following, in order of cost/latency tradeoff:
- **NOAA/NCEI Storm Events Database** and **NWS/SPC hail reports** — public-domain, free, but reporting lag can run hours to days behind the actual storm.
- **MRMS (Multi-Radar Multi-Sensor) hail-swath radar data** — near-real-time, the basis for most commercial swath products; use this (not forecast/model data) to avoid false-positive briefings sent for storms that didn't actually produce damaging hail at a given address (see `09-docs/risk_register.md` risk #15).
- **Commercial swath-to-address products** (e.g. Interactive Hail Maps/Hail Recon, GAF WeatherHub, a Swath API) — paid, turn MRMS radar into address-level property lists within minutes; recommended once storm-response volume justifies the cost.

Whichever source is used, populate `properties[].geom_geojson` from parcel data, not from the storm swath itself — the swath only determines *which* properties are in scope (via the PostGIS `storm_events.swath` ∩ `properties.geom` intersection), it is not the property boundary.

## Credentials referenced by n8n workflows

Create these as named credentials in n8n → Credentials before importing W1–W7:
`RGC_SUPABASE_SERVICE`, `RGC_HUBSPOT_PRIVATE_APP`, `RGC_GMAIL_OAUTH`, `RGC_OPENAI`, `RGC_FASTAPI_HMAC`, `RGC_RETELL_API`, `RGC_LINKEDIN_OAUTH`.

**Scripted setup:** `setup_n8n.py` in this directory creates the secret/API-key-based credentials (`RGC_SUPABASE_SERVICE`, `RGC_OPENAI`, `RGC_RETELL_API`, `RGC_FASTAPI_HMAC`) via n8n's REST API and imports W1, given an n8n instance URL + API key (`Settings → n8n API → Create an API key`). `RGC_GMAIL_OAUTH` and `RGC_LINKEDIN_OAUTH` cannot be scripted — they're OAuth2 credentials that need a human to complete the consent redirect in the n8n editor UI; there's no API-only path around that for either provider. `RGC_HUBSPOT_PRIVATE_APP` also isn't in the script since it's a single static token, easiest pasted directly into n8n's HubSpot credential form. See the script's docstring for exact env vars and usage.
