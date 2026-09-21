# W3 — Daily Evergreen Content

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_OPENAI`.

1. **Schedule Trigger** — cron `0 6 * * *`
2. **Postgres** — `select * from content_drafts where mode = 'evergreen' and scheduled_date = current_date` to pick up today's calendar slot (loaded via `01-supabase/008_content_calendar_seed.sql`, from `07-content/30_day_evergreen.md`; see `content_drafts.scheduled_date`)
3. **OpenAI** — Content Repurposing Agent (`04-agents/repurposing.md`), given that row's `title`/`body` as the creative brief
4. **OpenAI** — Compliance-Gate Agent (`04-agents/compliance_gate.md`), returns strict JSON `{"status","violations","rewrite","required_disclaimers"}`
5. **IF** `status == "pass"` → **Postgres** update that same row: `body = <repurposed copy>`, `compliance_status = pending_approval`
   **ELSE** → **Postgres** update that same row: `compliance_status = compliance_flag`, `compliance_report = <agent JSON>`
