# LinkedIn Community Management API — Application

## Legal / Org Details
- **Legal org:** Restoration GC (restorationgc.net)
- **Registered address:** 701 Brazos St, Austin, TX 78701
- **Business email:** michael@restorationgc.net (must be verified)
- **Privacy policy URL:** hosted at restorationgc.net/privacy (required before submission)

## Use Case Statement (for the access-request form)

> "Schedule and publish educational content to our own verified LinkedIn Company Page; retrieve our own Page analytics (impressions, reactions, comments) and surface comment/reaction notifications to an internal approval dashboard where a human reviews and approves every response before it is sent. We do not automate engagement, scrape member data, or post on behalf of third parties."

This matches LinkedIn's supported commercial use cases for the Community Management API while avoiding the User Agreement §8.2 automation prohibitions by keeping a human in the loop for every send.

## Data Handling

- OAuth tokens stored encrypted in n8n credentials (`RGC_LINKEDIN_OAUTH`).
- Analytics stored in Supabase `linkedin_metrics` (aggregate only).
- No member PII retained beyond what LinkedIn returns for our own Page.
- Refresh tokens rotated automatically by n8n's OAuth2 credential type.
- Access limited to Michael Johnson (MJ) + one admin.

## Screencast List (required for Standard tier)

The Development tier gives a 12-month build window; moving to Standard tier requires a screencast demonstrating each use case end to end:
1. Full OAuth consent flow
2. Posting to our Page
3. How comments/reactions display in the dashboard (aggregate + member-level)
4. The human-approval step before any reply is sent

High-resolution, downloadable, narrated video; only app screens visible (no other tabs/credentials shown).

## Application Checklist

- [ ] New app created against our verified Company Page
- [ ] App name excludes "Linked"/"In" — use **"RGC Engagement Console"**
- [ ] Page super-admin verifies the app
- [ ] Apply for Development tier first (12-month window) before requesting Standard tier
- [ ] Webhook endpoint implements the HMAC challenge handshake (see `03-n8n/fastapi_webhook_contract.md` conventions): return `{challengeCode, challengeResponse}` as JSON with a `200 OK` within 3 seconds, `content-type: application/json`; re-validated by LinkedIn every 2 hours; 3 consecutive failures blocks the webhook.
