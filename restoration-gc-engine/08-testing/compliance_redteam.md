# Compliance-Gate Red-Team Test Plan (46 prompts)

Each prompt is run through the Compliance-Gate Agent (`04-agents/compliance_gate.md`) against the seeded `compliance_rules` lexicon (`01-supabase/006_seed.sql`). Expected `status` is given for each. **Invariant under test:** any `severity = block` rule match must never yield `status = "pass"`.

## Results — Actually Run, Not Just Read

`run_redteam.py` is a reference implementation of the gate's deterministic layer (banned-phrase regex + required-disclaimer presence — the part that doesn't need an LLM call). It was run against the live `compliance_rules` table in the provisioned Supabase project. **Current result: 46/46 fixtures match their expected status, 0 invariant violations.**

That result required fixing 5 real bugs found by actually executing this suite (not just reading the regexes), all applied live and folded back into `01-supabase/006_seed.sql`:
1. **`us_no_guarantee`** — `\b100%\b` never matched "100% of homeowners..." because `\b` can't find a boundary between `%` and a following space (both non-word characters). Added a lookahead alternative.
2. **`tx_no_deductible` / `ok_no_deductible`** — the original `" ?deductible"` (optional single space) required near-adjacency to the trigger word, so it missed almost all realistic phrasing ("waive **your** deductible", "eat **the** deductible"). Rewritten to require "we" as the subject and allow a gap, which also fixes false-positive #12/#32 below.
3. **`il_no_deductible`** — `.{0,15}` gap was too narrow for phrasing like "inflate the estimate to cover your deductible"; widened to `.{0,40}`.
4. **`us_no_legal_advice`** — the bare `legal advice` alternative matched the *compliant* disclaimer's own negated phrasing ("does not ... provide **legal advice**"), meaning the required TX disclaimer would perpetually re-trigger the very rule it's supposed to satisfy. Narrowed to an affirmative-offer construction (`we provide/offer/give ... legal advice`); also broadened "bad faith case" to catch "bad-faith lawsuit" phrasing (fixture #3's original wording didn't literally match the old pattern — a real gap in the test itself, not just the rule).
5. **`tx_contract_notice` scope mismatch** — this rule is a *contract* disclaimer (TX Bus. & Com. Code §27.02(b) applies to signed contracts ≥$1,000), but it was firing against every TX-tagged LinkedIn post, carousel, and newsletter too. `content_drafts` never actually holds a contract (those are generated via DocuSign per the top-level README, outside this pipeline entirely), so this rule was structurally mis-scoped. Added `compliance_rules.applies_to` (`content` | `contract`); the Compliance-Gate Agent now excludes `applies_to = 'contract'` rules when checking `content_drafts`. `tx_contract_notice` stays active for a future dedicated contract-review checklist.

One fixture (`#43`) needed re-scoping rather than a lexicon fix: it was TX-tagged to test that an informational deductible mention ("your policy's deductible amount is listed on your declarations page") doesn't false-positive on the inducement pattern — a universal concern, not a TX-specific one — but the TX tag also pulled in the (unrelated) TX disclaimer requirement. Removed the TX tag; the fixture now correctly tests only what it was meant to.

**A 6th bug was found in a later pass, while verifying the loaded 30-day content calendar (`07-content/30_day_evergreen.md`) rather than by hand-writing a fixture.** Day 22 of that calendar is "IL 215 ILCS 5/155.51 deductible-fraud statute explained for property managers" — exactly the compliant, educational content this system exists to produce. But `il_no_deductible`, unlike `tx_no_deductible`/`ok_no_deductible`, had no first-person/offer subject scoping: `\b(waive|absorb|inflate)\b.{0,40}\bdeductible\b` fires on *any* mention of those words near "deductible", regardless of who's doing the waiving. A compliant sentence like "Illinois law prohibits a contractor from waiving your deductible" would have been forced into `status = "rewrite"` at `block` severity — the gate would have rejected its own required educational content. Fixed by adding the same `we(?:'ll| will| can| could| may)?` subject requirement TX/OK already use, so the rule still catches an actual offer ("we'll waive your deductible") but not a third-person explanation of the law. Added as fixtures #45–46 (both expect `pass`).

A **7th issue**, in the test harness rather than the lexicon itself: `run_redteam.py`'s docstring claimed `SUPABASE_ANON_KEY` would work as a read-only fallback. It doesn't — `compliance_rules`' RLS policy (`auth_read_rules`) is scoped to `authenticated`, not `anon`, so the anon key silently returns zero rows rather than an auth error. Every fixture then evaluates against an empty rule set and reports `actual=pass` across the board — a run that looks clean while testing nothing. Fixed the docstring and added an explicit zero-rules guard in `main()` that refuses to report a result rather than let this happen silently again.

Run it yourself: `python3 run_redteam.py` (needs `SUPABASE_URL` + a key with read access to `compliance_rules`, i.e. `service_role` or an authenticated session — the `anon` key's RLS policy doesn't cover this table, and the script now refuses to run rather than silently report a false pass).

## A. Universal banned-phrase tests (scope_state = OTHER, applies in every state)

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 1 | "We guarantee full payout on your claim" | ALL | `rewrite` | us_no_guarantee |
| 2 | "100% of homeowners who work with us get paid in full" | ALL | `rewrite` | us_no_guarantee |
| 3 | "You have a strong bad-faith lawsuit against your insurer" | ALL | `rewrite` | us_no_legal_advice |
| 4 | "We will file suit for you if they deny the claim" | ALL | `rewrite` | us_no_legal_advice |
| 5 | "We negotiate directly with your insurer to maximize your settlement" | ALL | `rewrite` | us_no_adjusting (Stonewater) |
| 6 | "We act as your adjuster throughout the process" | ALL | `rewrite` | us_no_adjusting |

## B. Texas-specific tests

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 7 | "We'll waive your deductible in Texas" | TX | `rewrite` | tx_no_deductible |
| 8 | "No deductible, no out-of-pocket cost — free roof!" | TX | `rewrite` | tx_no_deductible |
| 9 | "We'll cover your deductible so you pay nothing" | TX | `rewrite` | tx_no_deductible |
| 10 | TX $1,200 insurance-proceeds contract missing the contractor/non-adjuster disclaimer | TX | `flag` | tx_disclaimer (tx_contract_notice is `applies_to=contract` — not checked against content_drafts; see Results) |
| 11 | TX educational post missing the contractor/non-adjuster disclaimer | TX | `flag` | tx_disclaimer |
| 12 | Clean TX post: storm briefing + correct §707.002 deductible-must-be-paid language + the tx_disclaimer text present verbatim | TX | `pass` | (control) |

## C. Oklahoma-specific tests

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 13 | "We'll eat the deductible for you" | OK | `rewrite` | ok_no_deductible |
| 14 | "We'll pay your deductible so the repair is free" | OK | `rewrite` | ok_no_deductible |
| 15 | OK initial estimate missing the §1151.30 written notification | OK | `flag` | ok_notice |
| 16 | Clean OK post: storm briefing + the ok_notice text present verbatim, incl. §1151.30 | OK | `pass` | (control) |

## D. Florida-specific tests

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 17 | "We guarantee your Florida claim gets approved" | FL | `rewrite` | us_no_guarantee |
| 18 | FL post about filing a new claim, missing the 1-year notice deadline disclaimer | FL | `flag` | fl_deadline_disclaimer |
| 19 | Clean FL post: storm briefing + the fl_deadline_disclaimer text present verbatim, incl. §627.70132 | FL | `pass` | (control) |

## E. Illinois-specific tests

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 20 | "Our public adjuster will handle everything for you" | IL | `rewrite` | il_no_pa_referral (Bulletin 2026-02) |
| 21 | "We offer a paid referral to a licensed public adjuster" | IL | `rewrite` | il_no_pa_referral |
| 22 | "We'll waive your deductible on this Illinois claim" | IL | `rewrite` | il_no_deductible |
| 23 | "We can absorb part of your deductible" (IL) | IL | `rewrite` | il_no_deductible |
| 24 | "We'll inflate the estimate to cover your deductible" (IL) | IL | `rewrite` | il_no_deductible |
| 25 | Clean IL post: documentation-only language, no PA referral, no deductible language | IL | `pass` | (control) |

## F. Cross-state / combined violations

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 26 | "We guarantee we'll get you paid and we'll waive your Texas deductible" | TX | `rewrite` | us_no_guarantee + tx_no_deductible |
| 27 | "Our public adjuster will negotiate your Illinois claim and waive the deductible" | IL | `rewrite` | il_no_pa_referral + il_no_deductible + us_no_adjusting |
| 28 | "We act as your adjuster and guarantee full payout" (OK) | OK | `rewrite` | us_no_adjusting + us_no_guarantee |
| 29 | "We'll eat the Oklahoma deductible and guarantee 100% payout" | OK | `rewrite` | ok_no_deductible + us_no_guarantee |

## G. Clean-pass controls (should always return `pass`)

| # | Draft text | State tag | Expected |
|---|---|---|---|
| 30 | "Restoration GC documents storm damage and coordinates inspections. We are a licensed general contractor, not a public adjuster, and do not adjust claims or provide legal advice." | ALL | `pass` |
| 31 | "Here's what to check after a hailstorm: dated photos, your date of loss, and your full policy declarations page." | ALL | `pass` |
| 32 | "Texas law requires you to pay your deductible (Tex. Ins. Code §707.002); we help you plan for it. Restoration GC is a licensed general contractor, not a public insurance adjuster, and does not adjust claims or provide legal advice (Tex. Ins. Code §4102.163)." | TX | `pass` |
| 33 | "In Florida, notice of a new or reopened property claim is generally barred after 1 year from the date of loss (Fla. Stat. §627.70132)." | FL | `pass` |
| 34 | "Oklahoma law (59 O.S. §1151.30) requires this written notification: a roofing contractor may not pay any part of your deductible." | OK | `pass` |
| 35 | "Illinois law (215 ILCS 5/155.51) prohibits waiving or inflating deductibles. We document damage only." | IL | `pass` |
| 36 | Roof-life ROI Calculator result copy: "These figures are for planning discussion only — they don't reflect any insurance-claim value." | ALL | `pass` |

## H. Required-disclaimer / missing-notice edge cases

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 37 | LinkedIn post about TX storm event with no disclaimer of any kind | TX | `flag` | tx_disclaimer |
| 38 | Newsletter section discussing FL claims with no deadline mention | FL | `flag` | fl_deadline_disclaimer |
| 39 | OK initial estimate PDF template missing the §1151.30 notice block | OK | `flag` | ok_notice |
| 40 | TX contract for $1,500 roof replacement (insurance-proceeds expected) with no contractor/non-adjuster disclaimer | TX | `flag` | tx_disclaimer (tx_contract_notice is `applies_to=contract` — see Results; a real signed contract like this one would separately need it via a dedicated contract-review checklist, not the content-drafts gate) |

## I. Near-miss / should-NOT-trigger controls (false-positive check)

| # | Draft text | State tag | Expected | Notes |
|---|---|---|---|---|
| 41 | "We guarantee we'll show up on time for your inspection" | ALL | `rewrite` (known false positive) | The `us_no_guarantee` regex matches "we guarantee" regardless of context, so this correctly cannot return `pass` under the block-severity invariant — but it is a false positive (scheduling, not claim-outcome). Track as a lexicon refinement item, not a bug in the gate's pass/fail logic. |
| 42 | "Ask your independent public adjuster about code-upgrade coverage" (IL) | IL | `pass` | Mentions a PA the reader already has, not a referral Restoration GC is making/paying for. |
| 43 | "Your policy's deductible amount is listed on your declarations page" | ALL | `pass` | Informational deductible mention, not an inducement to waive/absorb it. Untagged deliberately — this tests the universal inducement pattern, not TX disclaimer completeness (that's #10/#11/#37). |
| 44 | "A licensed public adjuster or attorney can advise you on legal options" | ALL | `pass` | Correct compliant rewrite target — should not itself be flagged. |

**Note on #41:** flag this to counsel during the Week-2 red-team review (see README deployment step 3) — the `us_no_guarantee` regex is intentionally broad, and a small number of benign uses of "guarantee" (e.g., scheduling, workmanship warranty language reviewed separately by counsel) may need a narrower pattern or an allow-list exception before launch. Until then, the compliance gate's correct behavior is to flag/rewrite it rather than silently pass a block-severity match.
