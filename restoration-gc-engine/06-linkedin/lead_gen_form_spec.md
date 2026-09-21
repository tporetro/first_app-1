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
