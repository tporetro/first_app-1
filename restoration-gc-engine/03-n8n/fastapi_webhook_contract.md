# FastAPI Webhook Contract — api.restorationgc.net

```
POST /webhooks/storm-alert     (HMAC header X-RGC-Signature = hex(hmac_sha256(secret, raw_body)))
  body: {event_id, event_type, event_ts(ISO8601), max_hail_size_in, max_wind_mph, state, swath_geojson?, properties:[{parcel_id,address,geom_geojson,roof_sqft}]}
  resp 200: {status:"queued", draft:<uuid>}

GET  /approve?token=<uuid>&d=approve|edit|reject   (one-tap; writes approval_queue.decision, decision_ts)

POST /webhooks/retell-status   {call_id, owner_id, outcome, consent_verified:bool, ai_disclosed:bool}
```

All endpoints reject with `401` if the signature is invalid, and log to `consent_records`/`attribution_events` as applicable.

## Credentials referenced by n8n workflows

Create these as named credentials in n8n → Credentials before importing W1–W7:
`RGC_SUPABASE_SERVICE`, `RGC_HUBSPOT_PRIVATE_APP`, `RGC_GMAIL_OAUTH`, `RGC_OPENAI`, `RGC_FASTAPI_HMAC`, `RGC_RETELL_API`, `RGC_LINKEDIN_OAUTH`.
