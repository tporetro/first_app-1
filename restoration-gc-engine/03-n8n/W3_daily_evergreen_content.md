# W3 — Daily Evergreen Content

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_OPENAI`.

1. **Schedule Trigger** — cron `0 6 * * *`
2. **Postgres** — select today's slot from the content calendar (`07-content/30_day_evergreen.md`, loaded into `content_drafts` per deployment step 7)
3. **OpenAI** — Content Repurposing Agent (`04-agents/repurposing.md`)
4. **OpenAI** — Compliance-Gate Agent (`04-agents/compliance_gate.md`), returns strict JSON `{"status","violations","rewrite","required_disclaimers"}`
5. **IF** `status == "pass"` → **Postgres** insert draft with `compliance_status = pending_approval`
   **ELSE** → **Postgres** insert draft with `compliance_status = compliance_flag` and `compliance_report = <agent JSON>`
