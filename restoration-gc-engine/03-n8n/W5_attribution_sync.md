# W5 — Supabase ↔ HubSpot Attribution Sync

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_HUBSPOT_PRIVATE_APP`.

1. **Schedule Trigger** — every 15 minutes
2. **Postgres** — select `attribution_events where synced_to_hubspot = false`
3. **HubSpot** — create a timeline event / update contact properties for each row
4. **Postgres** — update `synced_to_hubspot = true`

Dedupe key: `hubspot_contact_id + event_name + occurred_at` (idempotent re-runs).
