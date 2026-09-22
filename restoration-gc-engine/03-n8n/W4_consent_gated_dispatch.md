# W4 — Consent-Gated Voice/Email Dispatch

**Implemented** as full, importable JSON in `W4_consent_gated_dispatch.json` (the second workflow in this build shipped that way, alongside W1) — import it via n8n's UI or `setup_n8n.py` once you're ready to activate it. It is imported **inactive**; activating it in the n8n editor is the actual "enable W4" step, and that's on you to do once both gates below are cleared, since this session has no n8n connector to flip it remotely.

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_RETELL_API`, `RGC_GMAIL_OAUTH`.

Depends on two `content_drafts`/`approval_queue` columns not present in the original schema, added when this workflow was built: `content_drafts.owner_id` (so the workflow knows *who* an owner-specific email/voice draft is for — there was previously no way to express that) and `approval_queue.dispatched_at` (so a scheduled run never re-sends an already-dispatched item — `decision`/`decision_ts` alone only record approval, not dispatch). See `01-supabase/002_schema.sql`.

**Two independent gates before activating, both now cleared per this build's README:** Retell consent-flow sign-off (MJ's call, not verifiable from code) and a clean compliance red-team run (`08-testing/compliance_redteam.md` — 44/44, 0 invariant violations, verified live). Clearing both doesn't itself activate the workflow — you still import and switch it on yourself.

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
