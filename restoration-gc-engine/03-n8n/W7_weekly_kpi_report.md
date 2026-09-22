# W7 — Weekly KPI Report

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_OPENAI`, `RGC_GMAIL_OAUTH`.

1. **Schedule Trigger** — cron `0 8 * * 1` (Mondays)
2. **Postgres** (parallel branches) — leads count, score distribution, consent rate, pipeline by owner_type
3. **Postgres** — `linkedin_metrics` for the past week
4. **OpenAI** — Weekly Performance Analyst (`04-agents/performance_analyst.md`)
5. **Gmail** — send report to `michael@restorationgc.net`

The analyst flags any `compliance_flag` drafts accumulated during the week and any drop in consent rate.
