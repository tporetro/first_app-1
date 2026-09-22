# LinkedIn Lead Gen Form Spec

## Fields (4)

| Field | Required | HubSpot mapping |
|---|---|---|
| Work email | Yes (required for native lead sync / contact creation) | `email` |
| First name | No | `firstname` |
| Company | No | `company` |
| Owner type (custom single-select: Building Owner / Asset Manager / Property Manager / REIT-Portfolio / Other) | No | `rgc_owner_type` |

## Requirements

- Native HubSpot lead syncing requires an eligible LinkedIn Page/ad-manager role.
- Privacy-policy URL is required by LinkedIn before the form can go live.
- HubSpot receives submissions via webhook and logs them as form submissions; standard fields use HubSpot's default mappings, custom fields (owner type) are manually remapped in HubSpot's ad integration settings.
- **Keep the form to 3–4 fields.** LinkedIn Lead Gen Forms auto-fill from the viewer's profile data and convert at roughly 13% on average, vs. roughly 2.35–9% for external landing pages, per LinkedIn's own benchmark data (as cited across 2024–2025 third-party marketing analyses). Every additional field beyond the 4 above trades conversion rate for data completeness — prefer enriching missing fields later (ZoomInfo/HubSpot enrichment) over lengthening the form.

## Sales Navigator → Daily Connection Queue

Separate from the Lead Gen Form itself: Sales Navigator saved searches by owner type/geography feed a daily connection-request queue that lands in `approval_queue` (`action = 'send_connection_request'`) for MJ's one-tap approval, capped at ≤ 20 connection requests/day (see `outreach_templates.md`). This queue is a manual-send flow — LinkedIn UA §8.2 prohibits automating the send itself — the API/Sales Navigator only supplies the candidate list and the draft note.
