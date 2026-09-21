# Attribution Dashboard Spec

**Model:** multi-touch — first-touch, last-touch, and linear attribution views.

## Widgets

1. Leads by magnet (`rgc_lead_magnet` breakdown)
2. Score distribution (`rgc_total_score` histogram)
3. Consent rate by channel (email vs. voice, from `consent_records`)
4. Pipeline by `owner_type`
5. Touches-to-meeting (average number of `attribution_events` before `meeting_booked`)
6. Source → Won linear-attribution revenue
7. LinkedIn contribution (impressions/clicks/new connections from `linkedin_metrics`, joined to won deals via `attribution_events.touch_channel = 'linkedin'`)

## Data Source & Sync

- Primary source: Supabase `attribution_events`, synced into HubSpot via n8n Workflow W5 (every 15 minutes).
- Dedupe key: `hubspot_contact_id + event_name + occurred_at`.
- `linkedin_metrics` stays aggregate (Page/post-level) and is not joined to individual contacts beyond the `touch_channel` tag captured at click-through.
