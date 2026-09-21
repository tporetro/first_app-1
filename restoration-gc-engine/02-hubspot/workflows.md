# HubSpot Workflows

## 1. Lead-Magnet Enrollment
- **Trigger:** `rgc_lead_magnet` is known (any value set).
- **Actions:** set lifecycle stage = Lead; set lead status = Educating; enroll contact in the owner-type nurture workflow (#2); create an `attribution_events` row (via W2/W5, `event_name = form_submit`).

## 2. Nurture by Owner Type
- **Trigger:** enrolled by Workflow #1.
- **Actions:** 5-email educational sequence, branching on `rgc_owner_type`:
  - REIT / portfolio track
  - NN-lease owner track
  - Religious / nonprofit track
  - Influencer track (broker / public adjuster / attorney)
- **Compliance:** every email carries the state-scoped disclaimer for `rgc_primary_state`, a physical mailing address, and a one-click unsubscribe link (CAN-SPAM, 16 CFR Part 316).

## 3. Consent-Gated Voice/Email Handoff
- **Trigger:** `rgc_total_score` ≥ 75 (SQL threshold).
- **Logic:**
  - IF `rgc_voice_consent` = Yes AND (for AI voice) `ai_voice_disclosed` = Yes → create task "Dispatch to Retell (verify consent)".
  - ELSE → route to email-only nurture, or flag for manual outreach.
- **Rule:** never auto-dial without a corresponding Supabase `consent_records` row (enforced again at the n8n layer in W4).

## 4. Inspection-Partner Dispatch
- **Trigger:** lead status = Inspection Scheduled.
- **Actions:** create a task assigned to the partner-network queue, including property address and `rgc_hail_score`; log an `attribution_events` row with `event_name = inspection_dispatched`.
