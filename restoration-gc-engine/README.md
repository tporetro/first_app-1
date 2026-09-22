# Restoration GC — Unified LinkedIn Management + Commercial Building-Owner Lead-Gen & Education Engine

Build package for Michael Johnson ("MJ") / Restoration GC: a compliance-verified educational marketing and lead-generation system for commercial building owners affected by storm damage, built on Supabase + HubSpot + n8n + FastAPI + LinkedIn's Community Management API.

**Core principle: "educate, never adjust."** Every layer of this system — the compliance lexicon, the agent prompts, the lead magnets, the outreach templates — enforces no outcome guarantees, no deductible inducements, no legal advice, state-scoped disclaimers, and human approval of every LinkedIn send and every consent-gated voice/email dispatch.

## File Tree

```
restoration-gc-engine/
├── README.md
├── 01-supabase/            SQL migration: 11 tables (incl. portfolios), PostGIS, RLS, triggers, compliance seed
├── 02-hubspot/             Custom properties, lead-scoring model, workflows, attribution dashboard
├── 03-n8n/                 W1 + W4 (importable JSON) + W2, W3, W5–W7 specs + FastAPI webhook contract
├── 04-agents/              6 agent system prompts (shared guardrail block + role-specific)
├── 05-lead-magnets/        5 single-file HTML lead-magnet pages
├── 06-linkedin/            Community Management API application, profile/company rewrite,
│                           Lead Gen Form spec, outreach templates
├── 07-content/             30-day evergreen content calendar, curriculum spine, storm-response pack
├── 08-testing/             Test plan, 44-prompt compliance red-team suite (run_redteam.py), fixtures
├── 09-docs/                Risk register, detailed state-law reference
└── 10-fastapi/             FastAPI webhook backend (storm-alert, approve, retell-status) + tests
```

> Note: the source blueprint's file tree lists `W1..W7.json`. Only W1 is a fully importable n8n workflow JSON in this build; W2–W7 are delivered as node-by-node specs (`.md`) using the same n8n node vocabulary, to be assembled and pinned to your installed node `typeVersion`s in your n8n instance (see `03-n8n/` for details).

## Architecture

```mermaid
flowchart LR
  FA[FastAPI api.restorationgc.net] -->|HMAC webhook| W1[n8n W1]
  LM[Lead-magnet HTML] --> HS[(HubSpot)]
  LM --> SB[(Supabase)]
  W1 --> SB
  W2[W2] --> HS & SB
  W3[W3 evergreen] --> CG[Compliance-Gate Agent] --> SB
  SB --> W6[W6 digest] --> GM[Gmail → MJ one-tap]
  MJ((MJ approves)) --> W4[W4 dispatch]
  W4 -->|consent verified| RT[Retell voice] & GM
  SB <--> W5[W5] <--> HS
  LI[LinkedIn API] --> SB
  W7[W7 KPI] --> GM
```

## Deployment Order

1. **Supabase — done.** Project `restoration-gc-engine` (ref `bccpaguzuowwgokxgsjh`, org `michael@rgcroof.com's Org`, region `us-east-1`) is provisioned and migrated: `001_init.sql` through `006_seed.sql` applied, verified against `007_verify.sql` (PostGIS 3.3.7 active, RLS enabled with ≥1 policy on all 11 app tables, 11 compliance rules seeded across TX/IL/FL/OK/OTHER). A follow-up hardening pass closed everything the security/performance advisors could flag except three PostGIS/platform-level items documented in `007_verify.sql` (RLS on the `spatial_ref_sys` system table, the `postgis`/`citext` extensions living in the `public` schema, and `st_estimatedextent`'s `SECURITY DEFINER` grant) — all low-risk and left as-is. `008_content_calendar_seed.sql` (step 7) later added `content_drafts.scheduled_date` and loaded the 30-day calendar. **Note:** the same org also holds an older, unrelated-looking paused project (`rgcroof12`) — this build uses `restoration-gc-engine`, not that one; don't point env vars at `rgcroof12` by mistake.
   - `SUPABASE_URL` and `SUPABASE_ANON_KEY` are pulled below. `SUPABASE_SERVICE_KEY` still needs to be grabbed manually (see the checklist) before continuing to step 4.
2. **HubSpot — properties scripted, workflows manual.** This session's HubSpot integration (michael@rgcroof.com's portal, hub ID `246969128`) can manage CRM records and marketing content but has no tool for creating custom property definitions or automation workflows — those need HubSpot's own APIs/UI. Run `02-hubspot/create_properties.py` (needs a private app token with `crm.schemas.contacts.write`) to create the `restorationgc` property group and all 12 custom properties on Contacts in one shot; re-run with `--object-type companies` if you also want them on Company records. Then build the 4 workflows by hand in HubSpot's workflow editor, following `02-hubspot/workflows.md`; note the `subscriptionTypeId`s you create for use in the lead-magnet pages. **Note:** this portal hasn't completed HubSpot's own onboarding flow yet (unrelated to this build) — HubSpot may prompt for that separately.
3. **n8n — scripted where possible.** This session has no n8n MCP server/connector, so nothing here was run against a live n8n instance; run `03-n8n/setup_n8n.py` yourself against your own instance (needs `N8N_BASE_URL` + an n8n API key) to create the 4 secret-based credentials and import **both** W1 and W4 in one shot (`--skip-w4` if you don't want W4 in your instance yet). Both import **inactive** — the script never activates anything. `RGC_HUBSPOT_PRIVATE_APP` is a single token, easiest pasted directly into n8n's HubSpot credential form. `RGC_GMAIL_OAUTH` and `RGC_LINKEDIN_OAUTH` can't be scripted at all — n8n's API can create the credential shell but not complete the OAuth consent redirect, so those two need a human in the n8n editor regardless of tooling. Build W2, W3, W5–W7 from their specs in `03-n8n/`; set webhook URLs. **Activating W4 is a manual step in the n8n editor, done only after both gates in step 9 below are cleared — this build never flips that switch for you.**
4. **Lead magnets — hosted, HubSpot form wiring still needed.** `__SUPABASE_URL__`, `__SUPABASE_ANON_KEY__`, and `__HS_PORTAL_ID__` are filled in with real values in all 5 pages. Fixed a real bug while preparing these for hosting: `subscriptionTypeId:__EMAIL_SUB_ID__` was an unquoted placeholder — a bare JS identifier, not a string — so the first real form submission would have thrown `ReferenceError` while building the HubSpot request body, aborting the whole submit handler *before* the Supabase writes ran (silently losing every lead and consent record, with no visible error). Quoted it as a string and wrapped the HubSpot call in try/catch so a bad/placeholder form GUID or subscription ID — or a HubSpot outage — can never block the Supabase writes, which are this system's actual source of truth.

   **Hosted** on GitHub Pages: all 5 pages + an index are pushed to this repo's `gh-pages` branch (root). **One manual step remains** — GitHub's Pages-enable toggle isn't exposed as an API this session's tools can call: go to **Settings → Pages → Source → Deploy from a branch → `gh-pages` / `(root)` → Save**. Once saved, the pages go live at `https://tporetro.github.io/first_app-1/` (e.g. `.../scorecard.html`). That URL won't match `rgchub.com` from the docs — point a custom domain there via GitHub's "Custom domain" field + your own DNS CNAME record if you want the real domain; that step needs your DNS access, which isn't something any tool here has.

   Still outstanding, and not scriptable from this session (no tool here can create HubSpot Forms or Subscription Types):
   - Create 5 HubSpot Forms (Marketing → Forms), one per lead magnet, and copy each form's GUID into that page's `__HS_FORM_GUID_<MAGNET>__` placeholder (e.g. `__HS_FORM_GUID_SCORECARD__` in `scorecard.html`) — then re-push to `gh-pages`.
   - Create (or find) the "Email educational information" Subscription Type under Settings → Communication Preferences, and replace `'__EMAIL_SUB_ID__'` (all 5 pages) with its numeric ID (unquoted, since HubSpot expects a number there) — then re-push to `gh-pages`.
   - Until both are done, HubSpot sync silently no-ops (by design, per the fix above) — **Supabase capture works today, right now, once Pages is enabled.**
5. **FastAPI — done.** `10-fastapi/main.py` implements all 3 endpoints with HMAC verification; 14 tests in `10-fastapi/test_main.py` were run against the real code (not just read over) and all pass — HMAC verification, payload validation, n8n forwarding + downstream-failure handling, the approve endpoint's idempotency, and the retell-status consent/disclosure gate. Deploy it to any ASGI host (Railway, Fly.io, your own container) — no hosting connector is attached to this session, so provisioning wherever it runs is on you. See `10-fastapi/README.md` for env vars and deploy notes.
6. **LinkedIn:** file the Community Management API application (`06-linkedin/community_api_application.md`); publish the profile/Company Page rewrite (`06-linkedin/profile_rewrite.md`).
7. **Content — done.** All 30 rows from `07-content/30_day_evergreen.md` are loaded into `content_drafts` in the live `restoration-gc-engine` Supabase project (`mode = 'evergreen'`, `compliance_status = 'generated'`, scheduled sequentially via `scheduled_date` starting today) via `01-supabase/008_content_calendar_seed.sql`. That migration also added `content_drafts.scheduled_date` (not in the original schema) since nothing told W3 which calendar row is "today's slot" without it — W3's spec was updated to select `where scheduled_date = current_date`. Loading the calendar again elsewhere: run `008_content_calendar_seed.sql` once against a fresh project (it has no dedupe key, so re-running it duplicates rows — check the table is empty first).
8. **Counsel review — done.** Counsel reviewed and approved the compliance lexicon and disclaimers.
9. **Enable W4 — both gates cleared, activation is on you.** The red-team run is genuinely clean: `08-testing/run_redteam.py`, run against the live `compliance_rules` table (not just read over), found and fixed 5 real bugs (a false-negative that made the deductible-inducement rules miss almost all realistic phrasing, a `100%` word-boundary bug, a false positive where the required TX disclaimer's own text re-triggered the legal-advice rule, and a scope mismatch where a contract-only disclaimer was firing against ordinary LinkedIn posts) — see `08-testing/compliance_redteam.md` for the full writeup. Current result: **44/44 fixtures match expected status, 0 `block`-severity items marked `pass`.** MJ has signed off on the Retell consent flow. With both gates cleared, W4 (`03-n8n/W4_consent_gated_dispatch.json`, importable via `setup_n8n.py`) is ready — but it imports **inactive** by design, and activating it (n8n editor → open the workflow → toggle Active) is a manual step this build deliberately never automates, since nothing in code can substitute for a human's own decision to flip on real outbound dispatch.

## Env / Credential Checklist

`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_ANON_KEY`, `HUBSPOT_PRIVATE_APP_TOKEN`, `HS_PORTAL_ID`, `HS_FORM_GUID` (×5, one per lead magnet), `EMAIL_SUB_ID`, `OPENAI_API_KEY`, `RETELL_API_KEY`, `FASTAPI_HMAC_SECRET`, `LINKEDIN_CLIENT_ID`/`LINKEDIN_CLIENT_SECRET`, `GMAIL_OAUTH`.

**Supabase values for the provisioned `restoration-gc-engine` project** (ref `bccpaguzuowwgokxgsjh`):

| Var | Value |
|---|---|
| `SUPABASE_URL` | `https://bccpaguzuowwgokxgsjh.supabase.co` |
| `SUPABASE_ANON_KEY` (legacy JWT anon key) | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJjY3BhZ3V6dW93d2dva3hnc2poIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwMDUxNDksImV4cCI6MjEwNTU4MTE0OX0.Ae-YTG2re904E0xaT3sdRLOA3ug_L9mdVPHDJddhLic` |
| Modern equivalent (`sb_publishable_...`, recommended for new setups) | `sb_publishable_jrNisMpe0JdAdODEuFrsYQ_wTUY8lBp` |
| `SUPABASE_SERVICE_KEY` | **Not pulled here** — it bypasses RLS entirely and the Supabase tooling used to provision this project deliberately doesn't expose it. Grab it yourself: Supabase Dashboard → this project → Project Settings → API → Project API keys → `service_role`. Only ever put it in n8n's `RGC_SUPABASE_SERVICE` credential and the FastAPI backend's env — never in the lead-magnet HTML pages or any client-side code. |

Both the anon key and the publishable key are safe to embed client-side (in the lead-magnet pages' `__SUPABASE_ANON_KEY__` placeholder) — they're meant to be public and are constrained entirely by the RLS policies in `01-supabase/004_rls.sql`.

## Requires MJ's Own Credentials / Approval

- LinkedIn Community Management API application (business email verification + Page super-admin verification)
- HubSpot / Supabase / n8n admin access
- Retell consent-flow sign-off before W4 is enabled
- **Counsel review of all educational content and the compliance lexicon before first send**
- DocuSign for any contracts (must include the TX §27.02(b) notice — see `01-supabase/006_seed.sql` rule `tx_contract_notice`)

## Monitoring

- n8n execution-error alerts routed to Gmail.
- Supabase log drain.
- Weekly consent-rate + compliance-flag review via W7 (`03-n8n/W7_weekly_kpi_report.md`).
- **Token refresh:** LinkedIn/HubSpot OAuth auto-refresh via n8n credentials; LinkedIn webhook re-validates every 2 hours (must respond `200` JSON within 3 seconds, or 3 consecutive failures blocks it).
- **Rollback:** every SQL migration is idempotent (`if not exists` / `do $$ ... exception when duplicate_object`); n8n workflows are versioned via export; disabling W4 halts all outbound instantly.

## KPIs

Full funnel chain (see `02-hubspot/attribution_dashboard.md` for the widget-level detail and the W-shaped attribution model): **impressions → engagement rate → lead-magnet conversion → MQL → SQL → booked inspection → signed claim → revenue.** Track alongside: Lead Gen Form conversion rate (benchmark ~13%), connection acceptance rate, spam-complaint rate (< 3%), briefing→assessment conversion (storm-response mode), and cost per booked inspection.

## Recommendations (Staged)

1. **Now:** run the Supabase migration; file the LinkedIn Community Management API application (longest lead time); send the lexicon to counsel. *Threshold to proceed:* PostGIS + RLS verified; counsel sign-off received.
2. **Week 1:** deploy HubSpot properties/workflows, lead magnets, W1–W3 and W5–W7 (leave W4 off). *Threshold:* W1 dry-run passes with the hail fixture (`08-testing/fixtures/hail_event.json`); consent rows write correctly.
3. **Week 2 — done.** Both gates on W4 are cleared (clean red-team run, Retell consent-flow sign-off); W4 exists as importable JSON and is ready to activate manually per step 9 above. *Threshold to expand IL activity:* confirm no paid PA-referral model exists (IL DOI Bulletin 2026-02) — if any partner arrangement involves "anything of value" for PA lead-gen, do not launch it in IL.
4. **Ongoing:** weekly W7 review; if the compliance-flag rate exceeds 5% of drafts or the consent rate drops below 40%, pause the affected channel and re-tune the Content/Compliance agents.

### 30/90-Day Roadmap (mapped onto the staged plan above)

- **Days 1–30:** schema + HubSpot properties + LinkedIn API app filed; 3 highest-intent lead magnets live (scorecard, deadline checker, underpaid diagnostic); daily approval queue running; evergreen calendar live; consent fields in place. Maps to Recommendations steps 1–2 above.
- **Days 31–60:** storm-response mode live; owner-type nurture tracks (including the NN-lease roof-responsibility qualifying question); portfolio maps for REIT/asset-manager owners (`portfolios` table); Retell consent flow signed off. Maps to Recommendations step 3.
- **Days 61–90:** attribution dashboard live with the W-shaped model; A/B testing across formats; inspection-partner handoff SLA; webinar engine for high-intent portfolio owners. Maps to Recommendations step 4 (ongoing).

## Caveats / Unverified Items

- **IL Bulletin 2026-02 does not itself cite 215 ILCS 5/155.51 / PA 098-0862** — those are separate deductible-fraud statutes, kept as distinct lexicon rules (the Bulletin anchors on Article XLV: §§1510, 1515, 1610).
- **FCC July 2024 AI-disclosure NPRM (CG Docket 23-362) is proposed, not final** — this build already includes an AI-voice disclosure as best practice; monitor for a final rule that may add specific consent/disclosure mandates.
- **HubSpot's "v3" form-submission endpoint is the legacy `integration/submit` path** — there is no newer supported alternative as of this build.
- **HubSpot lead-scoring UI varies by tier/edition** — `02-hubspot/lead_scoring_model.md` expresses the model as portable point rules on custom number properties so it works regardless of which native scoring UI your HubSpot tier exposes; verify at deploy time.
- **W1 is a fully importable n8n workflow JSON; W2–W7 are node-by-node specs**, not raw importable JSON — assemble and pin to your installed n8n node `typeVersion`s.
- **TX Ch. 542A interest rate (currently ~13.5%) floats** with Finance Code §304.003 + 5% — re-check the current published rate at deploy time.
- The `ok_no_deductible` pattern rule in `01-supabase/006_seed.sql` was added to this build (not explicitly enumerated in the original blueprint's seed list) to close a gap: OK's own statute (59 O.S. §1151.30) prohibits deductible-inducement advertising the same way TX and IL statutes do, but the original seed only included an OK required-disclaimer rule, not a matching banned-phrase pattern.
- **This build was reconciled against a second, later strategy blueprint** covering the same system from a different angle (curriculum framing, LinkedIn-native lead-gen mechanics, a W-shaped attribution model, and richer state-law citations). Rather than duplicate structures, the genuinely new elements were folded in: the `portfolios` table (for REIT/asset-manager cross-property reporting), `content_drafts.asset_urls`, `attribution_events.campaign_id`, the `send_connection_request` approval-queue action, the W-shaped attribution model, `07-content/curriculum.md`, and `09-docs/state_law_reference.md`. Where the two blueprints described the same mechanism with different field names (e.g. `storm_events`/`compliance_rules` column naming), this build kept its existing, already-deployed schema rather than renaming columns, to avoid a breaking migration with no functional benefit.
