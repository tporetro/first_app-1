# W6 — Daily Approval-Queue Digest

Credentials used: `RGC_SUPABASE_SERVICE`, `RGC_GMAIL_OAUTH`.

1. **Schedule Trigger** — cron `0 7 * * *`
2. **Postgres** — select `approval_queue where decision is null`, joined to `content_drafts`
3. **Code** — render a mobile-friendly HTML digest with one-tap links:
   `https://api.restorationgc.net/approve?token={one_tap_token}&d=approve|edit|reject`
4. **Gmail** — send to `michael@restorationgc.net`
