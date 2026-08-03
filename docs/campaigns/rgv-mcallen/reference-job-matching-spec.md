# Spec: Reference-Job Matching Stage

### For the RGV/McAllen "nearby job" outreach campaign

**Purpose:** Before a lead is pushed to Retell for the RGV/McAllen script, pair it with a real, currently-active Restoration GC job close enough to legitimately claim as "nearby." This feeds the `{{reference_street}}` variable. If no valid match exists, the lead must NOT be routed through this script.

**Radius note (2026-08-03):** The initial production run against the 69-lead RGV batch used a 1-mile radius and matched only 4/69, all to one job. At MJ's direction the radius was widened to 6 miles for that run (max actual distance across the batch: 5.64 mi — all matches stayed inside the McAllen/Edinburg/Hidalgo metro footprint), which brought coverage to 69/69 across 7 distinct jobs. Flagging since the script's Phase 1 line ("not far from your property") is written for street/same-neighborhood proximity — at the top end of a 6-mile radius that phrasing is a stretch even though the underlying job/insurance/timing facts stay true. Worth revisiting radius vs. script wording together as more active-job coverage comes online.

This slots into [[storm-lead-automation]] as a new enrichment step, immediately before the Retell push — after property enrichment, before the outbound call is queued.

-----

## 1. Data required: Active Jobs Table

A source of truth listing RGC's real, currently active/recent jobs. This likely doesn't exist yet in a queryable form — needs to be created or pulled from wherever job data already lives (RGC Portfolio Connect? A CRM? Manual list?).

Minimum fields per job:

- `job_id`
- `street_address` (or at minimum street name — this is what populates `{{reference_street}}`)
- `city`, `state`
- `lat`, `lng`
- `job_status`: `active` | `completed` | `scheduled`
- `insurance_funded`: true/false — only insurance-funded jobs should be cited, since that's the specific claim in the script
- `status_effective_date` — when it entered its current status
- `client_consented_to_reference`: true/false — **new field, needs sign-off.** Using a real client's job/address as a sales hook to their neighbors may need that client's awareness or consent depending on how specific the reference gets. Flagging this as a decision point, not assuming yes.

## 2. Matching Logic

For each candidate lead (property record with lat/lng):

1. Query Active Jobs Table for jobs where:
- `job_status` is `active` or `scheduled` (not `completed` — a finished job isn't "we're doing work" in present tense)
- `insurance_funded = true`
- `client_consented_to_reference = true`
1. Filter to jobs within **radius R** of the lead (suggest starting at 1 mile for "same street/nearby" plausibility — tighter than your general prospecting radius, since this is a specific factual claim, not a broad area claim)
1. If multiple matches: pick the nearest one.
1. If zero matches: **lead is excluded from the RGV/McAllen reference-street script.** Do not fall back to a farther job or a completed one — that breaks the claim-precision rule already built into the prompt. Route the lead to the standard cold-outreach script (the original hail-data-hook version) instead, or hold it for a future pass once a closer job exists.

## 3. Freshness / Expiry

- A matched reference job should be re-validated on a schedule (daily, or whenever the campaign batch runs) — jobs move from `scheduled` → `active` → `completed`, and a completed job should drop out of the eligible pool immediately.
- Suggest a max age: don't cite a job as "we're doing work" if `status_effective_date` is more than ~30 days old, even if still technically `active` — avoids the claim going stale mid-campaign.

## 4. Output → Retell Variable Mapping

For each matched lead, the pipeline should pass to Retell:

- `reference_street` = matched job's `street_address` (or just street name, per how the script phrases it — currently script says "{{reference_street}}" as a bare street reference, e.g. "over on Nolana Ave")
- Keep `job_id` attached internally (not passed to Retell) for traceability — if a call disposition comes back and someone wants to audit which reference job was cited on which call, you need this link.

## 5. Failure / Edge Cases to Handle

| Case | Behavior |
|---|---|
| No active job within radius | Exclude from this campaign; route to standard script or hold |
| Job flips to `completed` between matching and call time | Needs a pre-call freshness check if there's a lag between matching and dialing — re-verify status_effective_date isn't stale |
| Two leads matched to the same reference job | Fine — multiple neighbors of one job is exactly the intended use case, no dedup needed here |
| `client_consented_to_reference` not yet decided as a field/policy | **Blocking — resolve before this campaign goes live.** Recommend confirming with the referenced client (or at minimum with Michael/Mendel on whether client sign-off is standard practice) before using their job as a sales hook to neighbors |

-----

## Open Decision for MJ

The consent field (`client_consented_to_reference`) is the one piece I won't assume an answer to — whether RGC already has a norm for this (e.g., always fine since it's public-facing work anyway) or needs explicit client sign-off first. Worth a quick answer before Claude Code builds against this table, since it changes what data needs to be collected and by whom.
