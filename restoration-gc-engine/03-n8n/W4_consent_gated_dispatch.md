# W4 — Consent-Gated Voice/Email Dispatch

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_RETELL_API`, `RGC_GMAIL_OAUTH`.

**Kept disabled until Retell consent-flow sign-off (see README deployment step 9).**

1. **Schedule Trigger**
2. **Postgres** — select `approval_queue` items with `decision = 'approve'` and `action in ('send_email','dispatch_voice')`
3. **Postgres** — select the latest matching `consent_records` row for the owner/channel
4. **IF** `action == 'dispatch_voice'`:
   - require `channel = 'voice' AND consent_given = true AND ai_voice_disclosed = true`
   - **ELSE** → stop and log (do not dispatch)
   **IF** `action == 'send_email'`:
   - require `channel = 'email' AND consent_given = true`
   - **ELSE** → stop and log
5. **HTTP Request** (Retell, for voice) or **Gmail** node (for email)
6. **Postgres** — update `approval_queue.decision_ts`; insert `attribution_events` row

**Rule:** no dispatch without a matching consent row. This is enforced twice — once here and once by the `chk_consent_disclosure` DB constraint on `consent_records`.
