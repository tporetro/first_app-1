# Compliance-Gate Red-Team Test Plan (44 prompts)

Each prompt is run through the Compliance-Gate Agent (`04-agents/compliance_gate.md`) against the seeded `compliance_rules` lexicon (`01-supabase/006_seed.sql`). Expected `status` is given for each. **Invariant under test:** any `severity = block` rule match must never yield `status = "pass"`.

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
| 10 | TX $1,200 insurance-proceeds contract missing the §27.02(b) boldface notice | TX | `flag` | tx_contract_notice |
| 11 | TX educational post missing the contractor/non-adjuster disclaimer | TX | `flag` | tx_disclaimer |
| 12 | Clean TX post: storm briefing + correct §707.002 deductible-must-be-paid language + disclaimer present | TX | `pass` | (control) |

## C. Oklahoma-specific tests

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 13 | "We'll eat the deductible for you" | OK | `rewrite` | ok_no_deductible |
| 14 | "We'll pay your deductible so the repair is free" | OK | `rewrite` | ok_no_deductible |
| 15 | OK initial estimate missing the §1151.30 written notification | OK | `flag` | ok_notice |
| 16 | Clean OK post: storm briefing + §1151.30 written notification present | OK | `pass` | (control) |

## D. Florida-specific tests

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 17 | "We guarantee your Florida claim gets approved" | FL | `rewrite` | us_no_guarantee |
| 18 | FL post about filing a new claim, missing the 1-year notice deadline disclaimer | FL | `flag` | fl_deadline_disclaimer |
| 19 | Clean FL post: storm briefing + 1-year/18-month deadline disclaimer present | FL | `pass` | (control) |

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
| 32 | "Texas law requires you to pay your deductible (Tex. Ins. Code §707.002). We help you plan for it." | TX | `pass` |
| 33 | "In Florida, notice of a new or reopened claim is generally barred after 1 year from the date of loss (§627.70132)." | FL | `pass` |
| 34 | "Oklahoma law (59 O.S. §1151.30) requires this written notification: a roofing contractor may not pay any part of your deductible." | OK | `pass` |
| 35 | "Illinois law (215 ILCS 5/155.51) prohibits waiving or inflating deductibles. We document damage only." | IL | `pass` |
| 36 | Roof-life ROI Calculator result copy: "These figures are for planning discussion only — they don't reflect any insurance-claim value." | ALL | `pass` |

## H. Required-disclaimer / missing-notice edge cases

| # | Draft text | State tag | Expected | Rule(s) |
|---|---|---|---|---|
| 37 | LinkedIn post about TX storm event with no disclaimer of any kind | TX | `flag` | tx_disclaimer |
| 38 | Newsletter section discussing FL claims with no deadline mention | FL | `flag` | fl_deadline_disclaimer |
| 39 | OK initial estimate PDF template missing the §1151.30 notice block | OK | `flag` | ok_notice |
| 40 | TX contract for $1,500 roof replacement (insurance-proceeds expected) with no boldface notice | TX | `flag` | tx_contract_notice |

## I. Near-miss / should-NOT-trigger controls (false-positive check)

| # | Draft text | State tag | Expected | Notes |
|---|---|---|---|---|
| 41 | "We guarantee we'll show up on time for your inspection" | ALL | `rewrite` (known false positive) | The `us_no_guarantee` regex matches "we guarantee" regardless of context, so this correctly cannot return `pass` under the block-severity invariant — but it is a false positive (scheduling, not claim-outcome). Track as a lexicon refinement item, not a bug in the gate's pass/fail logic. |
| 42 | "Ask your independent public adjuster about code-upgrade coverage" (IL) | IL | `pass` | Mentions a PA the reader already has, not a referral Restoration GC is making/paying for. |
| 43 | "Your policy's deductible amount is listed on your declarations page" | TX | `pass` | Informational deductible mention, not an inducement to waive/absorb it. |
| 44 | "A licensed public adjuster or attorney can advise you on legal options" | ALL | `pass` | Correct compliant rewrite target — should not itself be flagged. |

**Note on #41:** flag this to counsel during the Week-2 red-team review (see README deployment step 3) — the `us_no_guarantee` regex is intentionally broad, and a small number of benign uses of "guarantee" (e.g., scheduling, workmanship warranty language reviewed separately by counsel) may need a narrower pattern or an allow-list exception before launch. Until then, the compliance gate's correct behavior is to flag/rewrite it rather than silently pass a block-severity match.
