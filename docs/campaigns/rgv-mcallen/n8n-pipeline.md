# n8n Production Pipeline (2026-08-03)

Discovered mid-session that a real n8n instance (`https://rgcroof.app.n8n.cloud`)
already hosts the intended orchestration layer for `[[storm-lead-automation]]`.
This documents what exists, what was broken, and what was fixed/added.

## Workflows

| Workflow | Schedule | Status |
|---|---|---|
| Commercial Hail Watch — Storm Ingestion | hourly | inactive |
| Commercial Hail Watch — Reonomy Enrichment | daily 10am | inactive |
| Commercial Storm Lead Automation (standard script) | daily 9am | **active** |
| RGV McAllen Reference Street Campaign (new) | daily 9:15am | **active** |
| Retell Call Outcome → Supabase | webhook | **active** |
| Outbound sales calls (Retell → HubSpot) | — | inactive, looks like a separate/legacy Google-Sheets-based design |

Ingestion and enrichment (NOAA hail data → `hail_events`, Reonomy property search →
`commercial_properties`) are left inactive — only the two calling workflows and the
outcome webhook were turned on, per explicit instruction. They will run daily
against whatever is already in `leads`, but nothing refills `leads` automatically
until ingestion/enrichment are also activated.

## Bugs found and fixed

1. **`post_call_analysis_data` was unconfigured on both Retell agents.** The
   active outcome webhook (`Retell Call Outcome -> Supabase`) reads
   `call.call_analysis.custom_analysis_data.{call_outcome,email_collected,
   decision_maker_reached,ai_disclosure_confirmed}` — none of these were being
   extracted, so `call_status` would have been silently nulled (`UPDATE leads
   SET call_status = $2 ...` with `$2` always null) the moment the webhook
   started firing. Configured matching `post_call_analysis_data` on both
   `agent_3881fe707b28d339dc848dbef5` (Alex - RGV McAllen) and
   `agent_0e0cd1baef689480cf71c33f61` (RGC Roofing - Inspection Scheduler),
   with `call_outcome`'s enum using the literal `do_not_call` value the
   webhook's `WHERE $2 = 'do_not_call'` check requires.
2. **Both agents had wrong/missing `webhook_url`.** Alex had none; RGC Roofing
   pointed at a webhook ID (`4209197d-...`) that doesn't match the actual
   webhook node's ID (`fda3d2c0-...`) — stale/orphaned. Both now point to
   `https://rgcroof.app.n8n.cloud/webhook/retell-call-outcome`.
3. **`Commercial Storm Lead Automation` never wrote `retell_call_id` back to
   the lead it just called.** The outcome webhook matches on `WHERE
   retell_call_id = $1`, so without this, every outcome update would have
   matched zero rows. Added a `Mark Lead Dialed` node after the Retell call.
4. **`daily_hit_leads` (the view the standard workflow queries) didn't
   exist at all** — the workflow was non-functional as configured before
   today.
5. **No do-not-call check and no phone dedup** in the original
   `Commercial Storm Lead Automation` design — it would have called anyone
   in the view, including opted-out numbers and the same phone number
   multiple times (the exact bug found in the reference-street Ruby runner's
   first live run, see `reference-job-matching-spec.md`). Both are now baked
   into the views themselves (see below), not left to each workflow to
   remember.

## New SQL (Supabase)

- **`active_jobs` table** — the CSV from `data/rgv_mcallen_active_jobs.csv`,
  loaded so matching can happen in SQL instead of only in the Ruby runner.
- **`reference_street_matches`** — one row per pending lead: nearest eligible
  `active_jobs` row within 6 miles (`ST_DWithin` on `geography`, matching the
  Ruby `ReferenceJobMatcher`'s radius/eligibility rules).
- **`daily_reference_street_leads`** — `reference_street_matches` joined back
  to lead/property data, phone-deduped (`DISTINCT ON`), DNC-scrubbed, and
  excludes any phone that already has a `retell_call_id` anywhere in `leads`.
  Includes a computed `city` (falls back to county when the address has no
  city segment — same fix as the Ruby runner) and `first_name`.
- **`daily_hit_leads`** — pending leads that do *not* match a reference job,
  same DNC/dedup treatment. This is what `Commercial Storm Lead Automation`
  queries.

Routing is now determined live by these views (via the `NOT EXISTS
(... reference_street_matches ...)` join), not by a persisted
`hook_path_used`/`call_status` marker set ahead of time — the earlier
`routed_standard_script` status set by the Ruby runner was reset back to
`pending` so those leads are visible to `daily_hit_leads`.

## Relationship to `lib/reference_street_campaign_runner.rb`

The Ruby runner (built earlier in this session, before the n8n pipeline was
discovered) still works standalone and was used for the first live batch. It
duplicates matching/dedup/DNC logic now also expressed in SQL views. It's not
wired into the n8n pipeline and isn't invoked by it — kept as-is for manual/
ad-hoc runs, but the n8n workflows above are now the system of record for the
recurring, unattended version of this pipeline.
