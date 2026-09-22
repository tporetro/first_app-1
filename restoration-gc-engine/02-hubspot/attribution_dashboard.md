# Attribution Dashboard Spec

**Model:** multi-touch — first-touch, last-touch, and linear attribution views, plus a **W-shaped model** as the primary reporting default given the 60+ day commercial sales cycle: 30% weight to first touch, 30% to lead creation, 30% to deal (opportunity) creation, and the remaining 10% split across all other touches. `attribution_events.campaign_id` groups touches (e.g. a `storm_event` ID or an evergreen content series) so the W-shaped weighting can be computed per campaign as well as per contact.

## KPI Funnel Chain

Track the full chain end to end, not just top-of-funnel engagement:

`impressions → engagement rate → lead-magnet conversion → MQL → SQL → booked inspection → signed claim → revenue`

Supporting metrics tracked alongside the chain:
- **Lead Gen Form conversion rate** — benchmark toward the ~13% LinkedIn Lead Gen Form average (vs. ~2.35–9% for external landing pages); if a form underperforms this, cut it to 3–4 fields before diagnosing further.
- **Connection acceptance rate** (from the daily human-approved connection queue).
- **Spam-complaint rate** — keep under 3%.
- **Briefing → assessment conversion** (storm-response mode specific).
- **Cost per booked inspection** — the primary paid-vs-organic budget-allocation signal; if it exceeds target after 60 days, shift budget from cold outreach toward storm-triggered briefings (highest-intent channel).

## Widgets

1. Leads by magnet (`rgc_lead_magnet` breakdown)
2. Score distribution (`rgc_total_score` histogram)
3. Consent rate by channel (email vs. voice, from `consent_records`)
4. Pipeline by `owner_type`
5. Touches-to-meeting (average number of `attribution_events` before `meeting_booked`)
6. Source → Won linear-attribution revenue
7. LinkedIn contribution (impressions/clicks/new connections from `linkedin_metrics`, joined to won deals via `attribution_events.touch_channel = 'linkedin'`)
8. Portfolio rollup — for REIT/asset-manager/portfolio owners, aggregate properties, storm exposure, and pipeline value by `properties.portfolio_id` (`rgc_portfolio_id` in HubSpot)

## Data Source & Sync

- Primary source: Supabase `attribution_events`, synced into HubSpot via n8n Workflow W5 (every 15 minutes).
- Dedupe key: `hubspot_contact_id + event_name + occurred_at`.
- `linkedin_metrics` stays aggregate (Page/post-level) and is not joined to individual contacts beyond the `touch_channel` tag captured at click-through.
