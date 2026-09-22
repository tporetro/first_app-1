# HubSpot Lead-Scoring Model

Manual HubSpot score `rgc_total_score` = `rgc_behavior_score` + `rgc_fit_score` (each capped at 60).

## Lifecycle / Lead-Status Map

Subscriber (email captured, no consent) → Lead (lead-magnet complete) → MQL (`rgc_total_score` ≥ 50) → SQL (score ≥ 75 AND voice/email consent = Yes) → Opportunity (inspection dispatched) → Customer (won).

Lead statuses: `New`, `Educating` (in nurture), `Consent Pending`, `Consent Granted`, `Inspection Scheduled`, `Handoff to Retell`, `Attorney/PA Referred`, `Nurture Paused`.

## Behavior Score (max 60)

| Trigger | Points |
|---|---|
| Lead-magnet completion | +15 |
| Second magnet completed | +10 |
| Email open | +2 (cap 10) |
| Email click | +5 (cap 15) |
| LinkedIn Lead Gen Form submission | +12 |
| Meeting booked | +25 |
| Pricing/ROI page visit | +8 |

## Fit Score (max 60)

| Trigger | Points |
|---|---|
| `owner_type` in {reit_portfolio, asset_manager, nn_lease_owner, shopping_center, industrial} | +20 |
| `owner_type` in {building_owner, religious_nonprofit} | +12 |
| `owner_type` in {broker, public_adjuster, attorney} (influencer) | +8 |
| `primary_state` in {TX, IL, FL, OK} | +15 |
| `roof_sqft` ≥ 20,000 | +15 |
| Active storm match (`rgc_hail_score` ≥ 1.5") | +10 |

## Thresholds

- **MQL:** total score ≥ 50
- **SQL:** total score ≥ 75
- **SQL → voice/email handoff:** requires `rgc_email_consent` = Yes (for email) or `rgc_voice_consent` = Yes AND `ai_voice_disclosed` = Yes (for voice). No handoff without a matching `consent_records` row in Supabase.

> Note (2025+ HubSpot editions): HubSpot has migrated scoring UIs across tiers. This model is expressed as portable point rules on `rgc_behavior_score` / `rgc_fit_score` / `rgc_total_score` so it can be implemented either in the native HubSpot scoring tool or via workflows that increment/decrement the custom number properties — verify the exact scoring-tool UI available on your HubSpot tier at deploy time.
