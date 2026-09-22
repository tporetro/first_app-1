-- Patterns below reflect fixes found by actually running the 44-prompt red-team suite
-- (08-testing/compliance_redteam.md, 08-testing/run_redteam.py) against this table live:
--   - us_no_guarantee: "100%" had a word-boundary bug (\b after "%" never matches when
--     followed by whitespace, since both are non-word characters) that let "100% of
--     homeowners..." slip through uncaught.
--   - tx_no_deductible / ok_no_deductible: the original " ?deductible" (optional single
--     space) required near-adjacency, so it missed almost all realistic phrasing ("waive
--     YOUR deductible", "eat THE deductible"). Rewritten to require "we" as the subject
--     (so it still catches inducements) while explicitly NOT matching the compliant,
--     required phrasing "you must pay your deductible" -- the old pattern's "pay your"
--     alternative matched both, including the rule's own suggested_rewrite text.
--   - il_no_deductible: gap of .{0,15} was too narrow for realistic phrasing like
--     "inflate the estimate to cover your deductible"; widened to .{0,40}. A second bug
--     found later, while verifying the loaded 30-day content calendar (which schedules an
--     "IL deductible-fraud statute explained" post): unlike tx_no_deductible/ok_no_deductible,
--     this rule had no first-person/offer subject scoping, so it fired on ANY mention of
--     waiving/absorbing/inflating near "deductible" -- including compliant educational
--     content explaining the ban itself (exactly what that scheduled post needs to say).
--     Added the same "we(...)?" subject requirement TX/OK already use, so it still catches
--     an actual offer ("we'll waive your deductible") but not a third-person explanation of
--     the law ("Illinois law prohibits a contractor from waiving your deductible").
--   - us_no_legal_advice: the bare "legal advice" alternative matched the compliant
--     disclaimer's own negated phrasing ("does not ... provide legal advice"), which
--     would otherwise self-flag the exact TX disclaimer these rules require. Narrowed to
--     an affirmative-offer construction, and broadened "bad faith case" to also catch
--     "bad-faith lawsuit" phrasing.
insert into public.compliance_rules (rule_key,scope_state,rule_type,pattern,is_regex,severity,message,suggested_rewrite,citation_url,applies_to) values
('us_no_guarantee','OTHER','pattern','\b(guarantee|guaranteed|we guarantee|100%|full payout|we get you paid)\b|100%(?=\W|$)',true,'block','Outcome guarantee prohibited (misleading claim).','We help document your loss so the claim is evaluated fairly.','https://www.ftc.gov/legal-library/browse/rules/can-spam-rule','content'),
('us_no_legal_advice','OTHER','pattern','\byou have a\b.{0,20}bad.?faith\s+(?:case|claim|lawsuit)\b|\byou should sue\b|\bwe(?:''ll| will)?\s+(?:give|offer|provide)\s+(?:you\s+)?legal advice\b|\bwe will file suit for you\b',true,'block','No legal advice — refer to counsel.','An attorney can advise you on legal options.',null,'content'),
('us_no_adjusting','OTHER','pattern','\b(we adjust your claim|we negotiate with your insurer|act as your adjuster|maximize your settlement)\b',true,'block','Unauthorized public adjusting language.','We document damage and scope; a licensed public adjuster or your attorney handles negotiation.','https://law.justia.com/cases/texas/supreme-court/2024/22-0427.html','content'),
('tx_no_deductible','TX','pattern','\bwe(?:''ll| will| can| could| may)?\s+(?:waive|absorb|rebate|cover|eat|pay)\b.{0,20}deductible\b|\bno ?deductible\b',true,'block','TX HB2102/§707.002 — cannot waive/absorb deductible.','Texas law requires you to pay your deductible; we help you plan for it.','https://www.tdi.texas.gov/consumer/storms/roofing-and-insurance-know-the-law.html','content'),
('tx_contract_notice','TX','required_disclaimer','Texas law requires a person insured under a property insurance policy to pay any deductible applicable to a claim made under the policy...',false,'block','TX Bus & Com §27.02(b) 12pt boldface notice required on $1000+ insurance-proceeds contracts. This is a CONTRACT requirement, not a marketing-content one -- applies_to=contract, so the Compliance-Gate Agent does not check it against content_drafts (LinkedIn posts, carousels, newsletters, etc.); contracts are generated via DocuSign, never via content_drafts.',null,'https://statutes.capitol.texas.gov/Docs/BC/htm/BC.27.htm','contract'),
('tx_disclaimer','TX','required_disclaimer','Restoration GC is a licensed general contractor, not a public insurance adjuster, and does not adjust claims or provide legal advice (Tex. Ins. Code §4102.163).',false,'warn','Attach TX educational disclaimer.',null,'https://statutes.capitol.texas.gov/Docs/IN/htm/IN.4102.163','content'),
('fl_deadline_disclaimer','FL','required_disclaimer','In Florida, notice of a new or reopened property claim is generally barred after 1 year from the date of loss (Fla. Stat. §627.70132).',false,'warn','Attach FL deadline disclaimer.',null,'https://www.flsenate.gov/laws/statutes/2022/627.70132','content'),
('ok_notice','OK','required_disclaimer','Oklahoma law (59 O.S. §1151.30) requires this written notification: a roofing contractor may not pay any part of your deductible.',false,'block','OK §1151.30 written notification required with initial estimate.',null,'https://law.justia.com/codes/oklahoma/title-59/section-59-1151-30/','content'),
('ok_no_deductible','OK','pattern','\bwe(?:''ll| will| can| could| may)?\s+(?:waive|absorb|rebate|cover|eat|pay)\b.{0,20}deductible\b|\bno ?deductible\b',true,'block','OK 59 O.S. §1151.30 (HB 1940) — roofing contractor may not advertise/promise to pay any part of the deductible.','Oklahoma law prohibits a roofing contractor from paying any part of your deductible; we help you plan for it.','https://law.justia.com/codes/oklahoma/title-59/section-59-1151-30/','content'),
('il_no_pa_referral','IL','pattern','\b(our public adjuster|we refer you to a public adjuster|paid referral)\b',true,'block','IL Bulletin 2026-02 — paid PA lead-gen requires PA license; avoid referral model in IL.','We document damage; you may independently choose a licensed public adjuster or attorney.','https://idoi.illinois.gov/content/dam/soi/en/web/insurance/companies/companybulletins/cb2026-02-public-adjuster-lead-generation-01-26-26-arg.pdf','content'),
('il_no_deductible','IL','pattern','\bwe(?:''ll| will| can| could| may)?\s+(?:waive|absorb|inflate)\b.{0,40}\bdeductible\b',true,'block','IL 215 ILCS 5/155.51 / PA 098-0862 — deductible fraud prohibited.','Illinois law requires you to pay your deductible.','https://www.ilga.gov/legislation/ilcs/','content');
