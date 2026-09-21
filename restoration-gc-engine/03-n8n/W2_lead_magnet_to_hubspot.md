# W2 — Lead-Magnet → HubSpot → Score → Nurture

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_HUBSPOT_PRIVATE_APP`.

1. **Webhook** `/lead-magnet` (POST)
2. **Code** — validate payload (email, magnet_slug, state required)
3. **Postgres** — insert into `lead_magnet_submissions` + `consent_records` (Supabase)
4. **HubSpot** node "Upsert Contact" — map `rgc_owner_type`, `rgc_primary_state`, `rgc_lead_magnet`, `rgc_email_consent`, `rgc_voice_consent`, `rgc_consent_ts`
5. **HTTP Request** — compute score (behavior + fit per `02-hubspot/lead_scoring_model.md`)
6. **HubSpot** — update `rgc_behavior_score` / `rgc_fit_score` / `rgc_total_score`
7. **IF** `rgc_total_score` ≥ 50 → set lifecycle = MQL, enroll in nurture workflow (#2)
8. **Respond to Webhook** — `{"status":"ok"}`
