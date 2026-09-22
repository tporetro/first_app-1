# LinkedIn Community Management API — Application

## Legal / Org Details
- **Legal org:** Restoration GC (restorationgc.net)
- **Registered address:** 701 Brazos St, Austin, TX 78701
- **Business email:** michael@restorationgc.net (must be verified)
- **Privacy policy URL:** `https://restorationgc.net/privacy-policy/` — confirmed live (redirects from `/privacy`) and substantive: covers PII collection, cookies/log files, and CCPA/GDPR rights. **Gap:** it does not currently mention LinkedIn, OAuth token handling, or the Community Management API data (Page analytics, comment/reaction data) this app will process — LinkedIn's developer terms expect the privacy policy to disclose what a connected API does with data. Add a short paragraph covering that before submitting the application; this is a live WordPress site (no CMS access from this session) so it needs a manual edit.

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

- [ ] New app created against our verified Company Page — **manual, LinkedIn Developer Portal**: no LinkedIn connector/API tool is available in this session to do this step for you
- [x] App name excludes "Linked"/"In" — use **"RGC Engagement Console"**
- [ ] Page super-admin verifies the app — **manual**, needs a human logged in as the Page's super-admin
- [ ] Apply for Development tier first (12-month window) before requesting Standard tier — **manual**
- [x] **Webhook endpoint implements the HMAC challenge handshake — done.** `GET /webhooks/linkedin` in `10-fastapi/main.py` computes `hmac_sha256(LINKEDIN_CLIENT_SECRET, challengeCode)` and returns `{challengeCode, challengeResponse}` as JSON with a `200 OK`; covered by 2 new tests in `10-fastapi/test_main.py` (16/16 passing). Set `LINKEDIN_CLIENT_SECRET` (from the Developer Portal's app "Auth" tab, once the app exists) alongside this service's other env vars, then register `https://<your-fastapi-host>/webhooks/linkedin` as the app's webhook URL — LinkedIn calls it once at registration and again every 2 hours; 3 consecutive failures blocks the webhook.
- [ ] Privacy policy updated to disclose LinkedIn API data handling (see gap noted above) — **manual**, requires editing the live restorationgc.net WordPress site
