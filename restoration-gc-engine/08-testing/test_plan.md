# Test Plan

## Compliance Gate

See `compliance_redteam.md` for the full 44-prompt suite. Pass criteria: 0 of the `block`-severity fixtures return `status = "pass"`; all clean-pass controls (section G) return `pass`.

## TCPA / Consent (n8n W4)

1. Attempt voice dispatch with **no matching consent row** → dispatch blocked, event logged, no call/HTTP request made to Retell.
2. Attempt voice dispatch with `voice consent = true` but `ai_voice_disclosed = false` → blocked by both the W4 IF-node logic and the `chk_consent_disclosure` database constraint on `consent_records`.
3. Attempt voice dispatch with full consent (`consent_given = true AND ai_voice_disclosed = true`) → dispatch proceeds, `attribution_events` row logged.
4. Attempt email dispatch without email consent → blocked.
5. Confirm unsubscribe/opt-out is honored within 10 business days (CAN-SPAM / FCC 24-24 revocation rule).

## Schema / RLS

1. Using the `anon` key: `INSERT` into `lead_magnet_submissions` and `consent_records` succeeds.
2. Using the `anon` key: `SELECT` against `owners` returns 0 rows (no anon read policy exists).
3. Using the `service_role` key: full CRUD access to all 10 tables succeeds.
4. Run `01-supabase/007_verify.sql` and confirm `rowsecurity = true` for all 10 tables, with ≥ 1 policy per table.

## n8n Dry-Run (W1)

1. POST the fixture at `fixtures/hail_event.json` to `/webhooks/storm-alert`.
2. Expect: a `storm_events` row is upserted, a `content_drafts` row is created with `compliance_status = pending_approval`, an `approval_queue` row is created with a `one_tap_token`, and the webhook responds `200` with `{"status":"queued","draft":<uuid>}`.

## Attribution Reconciliation (W5)

1. Insert 5 rows into `attribution_events` with `synced_to_hubspot = false`.
2. Run W5.
3. Expect: 5 corresponding HubSpot timeline events created, all 5 rows now have `synced_to_hubspot = true`.
4. Re-run W5 immediately.
5. Expect: no duplicate HubSpot timeline events (dedupe key: `hubspot_contact_id + event_name + occurred_at`).
