# State Law Reference — Detailed Citations

This is a **content-writer/agent reference**, not the compliance-rule engine itself — the enforceable lexicon lives in `01-supabase/006_seed.sql` (`compliance_rules`). This document holds the more granular statutory detail behind the curriculum (`07-content/curriculum.md`) and the Briefing Agent's deadline citations, so content creators and counsel can trace a claim back to its source. **All citations here must be re-verified by counsel before publication** — insurance law changes frequently and this reference has not been independently re-checked against current statute text in this pass.

## Texas — Chapter 542 / 542A (Prompt Payment of Claims)

- **§542.055** — insurer must acknowledge a claim, begin investigation, and request needed items by the 15th day (30th business day for surplus lines).
- **§542.056** — insurer must accept or reject the claim by the 15th business day after receiving the requested proof-of-loss items (extendable up to 45 days).
- **§542.057** — insurer must pay an accepted claim within 5 business days of acceptance.
- **§542.060(a)** — violations trigger 18% annual interest plus attorney's fees.
- **§542.060(c)** (Chapter 542A "forces of nature"/weather claims) — instead sets simple interest at 5% plus the Finance Code §304.003 rate (added by HB 1774, eff. 9/1/2017) — **this floating rate must be re-checked at time of use.**
- **§542A.003** — requires written pre-suit notice at least 61 days before filing suit, stating the specific acts/omissions, the specific amount owed, and attorney's fees.
- **§542A.007(d)** — failing to give proper pre-suit notice can abate the suit and bar post-filing attorney's fees.
- **§542A.006** — insurers may elect to accept an agent's liability, which commonly dismisses the individual adjuster from the suit and can enable removal to federal court.
- **§4102.163(a) / §4102.158** — bars a contractor from acting as, or advertising as, a public adjuster on property it may repair. Upheld in *Texas Dep't of Ins. v. Stonewater Roofing, Ltd. Co.*, No. 22-0427, 2024 WL 2869414 (Tex. June 7, 2024) — the court held these provisions regulate "representative capacity with a nonexpressive objective," and that a violator "is subject to administrative, criminal, and civil penalties." TDI guidance separately forbids advertising to "negotiate claim settlements," promising to "recover every dime," or claiming to "deal with insurance companies" — violations can void the underlying contract.
- **HB 2102 (2019) / §707.002** — bars contractors from waiving, absorbing, or otherwise inducing around a policyholder's deductible.
- **Bus. & Com. Code §27.02(b)** — mandatory boldface contract notice on insurance-proceeds contracts ≥ $1,000 (see `compliance_rules.tx_contract_notice`).

## Florida — SB 2-A (Dec. 2022)

- **§627.70132** — cut the initial claim-notice window to 1 year and the supplemental-claim window to 18 months from date of loss.
- **§627.70131** — insurer duties: 14-day (as amended, now 7-day per later amendment — verify current text) acknowledgment; 60-day pay-or-deny (down from 90).
- SB 2-A also eliminated one-way attorney fees for new policies written after the law's effective date.

## Oklahoma

- **OID Bulletin / 36 O.S. §6202** — treats "claim specialist"/"we deal with insurance companies" contractor advertising as unlicensed public adjusting.
- **59 O.S. §1151.30 (HB 1940)** — a roofing contractor may not advertise or promise to pay any part of a policyholder's deductible; requires a written notification with the initial estimate (see `compliance_rules.ok_notice` / `ok_no_deductible`).
- **36 O.S. §3629 / §1250.7** — insurer written offer/rejection within 90 days of proof of loss; investigation within 60 days (120-day outer limit; +20 days after a governor-declared catastrophe).

## Illinois

- **215 ILCS 5/1600 et seq. (Public Adjusters Law)** vs. the **Roofing Industry Licensing Act** — a roofing license is not public-adjuster authorization; IL contractors cannot interpret policy language or negotiate claims.
- **IL DOI Bulletin 2026-02** — addresses the contractor–public-adjuster referral/lead-generation model directly; see `compliance_rules.il_no_pa_referral` and the "do not launch a paid PA-referral model in IL" gate in the top-level README.
- **215 ILCS 5/155.51** — deductible-fraud statute (see `compliance_rules.il_no_deductible`).

## Commercial Claim Concepts to Teach (Cross-State)

- **ACV vs. RCV and depreciation holdback** — actual cash value pays out depreciated value first; replacement cost value releases the depreciation holdback after repairs are completed and documented.
- **Matching / uniformity** — whether an insurer must match undamaged sections to repaired ones (roof slopes, siding) varies by state and policy language.
- **Ordinance-or-law (code-upgrade) coverage** — pays for code-required upgrades triggered by a covered repair; frequently excluded or sublimited unless purchased as an endorsement.
- **Coinsurance penalties** — under-insuring relative to a coinsurance clause (commonly 80–90%) can penalize a claim payout proportionally; acute risk for churches, synagogues, and nonprofits that haven't updated insured values.
- **The appraisal clause and its traps** — a contractual alternative to litigation for amount-of-loss disputes; risks include biased umpire selection, appraisal binding the amount but not coverage questions, and appraisal sometimes staying (pausing) litigation rather than replacing it.
- **Underpayment/denial tactics to recognize** — excessive depreciation, unusually short inspections, narrow scope that omits tear-off/flashing/edge-metal/HVAC-curb disturbance, and repeated documentation demands that function to reset statutory response-time clocks.

## Federal

- **TCPA / FCC 24-17** — AI-generated voice is an "artificial or prerecorded voice" under the TCPA (FCC Declaratory Ruling, CG Docket No. 23-362, adopted Feb. 8, 2024). Marketing calls to cell numbers require prior express written consent; penalties run $500–$1,500 per call with no cap.
- ***Insurance Marketing Coalition Ltd. v. FCC***, No. 24-10277 (11th Cir. Jan. 24, 2025) — vacated the FCC's one-to-one consent rule, reverting to the prior, broader "prior express consent" standard.
- **CAN-SPAM** — commercial email needs no prior opt-in but requires accurate headers, a physical address, and a promptly honored opt-out.
- **State-level AI-voice disclosure laws** (e.g., California AB 2905) may impose disclosure requirements beyond the federal baseline — check the recipient's state before any AI-voice dispatch, not just the property's state.
