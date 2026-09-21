-- Loads the 30-day evergreen content calendar (07-content/30_day_evergreen.md) into
-- content_drafts as mode='evergreen', compliance_status='generated' rows, scheduled
-- sequentially starting today. W3 (03-n8n/W3_daily_evergreen_content.md) selects
-- `where scheduled_date = current_date` to pick up "today's slot", runs it through
-- the Content Repurposing + Compliance-Gate agents, and updates body/compliance_status.
--
-- Run once. There is no natural unique key on these rows (unlike compliance_rules'
-- rule_key), so re-running this file will insert 30 duplicate rows rather than fail
-- loudly or no-op — check `select count(*) from content_drafts where mode='evergreen'`
-- is 0 before running, or delete the prior batch first.
insert into public.content_drafts (mode, channel, state_tags, title, body, scheduled_date) values
('evergreen','linkedin_post','{}','Day 1 -- Series intro -- documented pre-loss condition','Why "documented pre-loss condition" matters more than people think -- intro post framing the series.', current_date + 0),
('evergreen','carousel','{TX}','Day 2 -- TX Ch. 542 prompt-payment timeline','TX Ch. 542 prompt-payment timeline explained (acknowledge 15 days, accept/reject 15 business days, pay 5 business days).', current_date + 1),
('evergreen','linkedin_post','{}','Day 3 -- 1999 Sydney hailstorm and pre-loss documentation','Uses the 1999 Sydney hailstorm (one of the largest insured hail losses in Australian history) to illustrate why documented pre-loss condition matters -- connected to modern drone/photo documentation.', current_date + 2),
('evergreen','comment','{}','Day 4 -- Comment prompts -- commercial roof inspections','Two prompts for engaging on industry posts about commercial roof inspections.', current_date + 3),
('evergreen','linkedin_post','{FL}','Day 5 -- FL SB 2-A deadline compression','FL SB 2-A deadline compression explained: 1-year notice, 18-month supplemental, 60-day pay-or-deny.', current_date + 4),
('evergreen','video_script','{}','Day 6 -- What educate, never adjust means','45-sec explainer: "What does ''educate, never adjust'' actually mean?"', current_date + 5),
('evergreen','carousel','{OK}','Day 7 -- OK 1151.30 written notification requirement','OK 59 O.S. Section 1151.30 -- the written notification every roofing estimate must include.', current_date + 6),
('evergreen','linkedin_post','{IL}','Day 8 -- IL public-adjuster lead-gen rules explained','Why Illinois treats public-adjuster lead-gen differently (IL DOI Bulletin 2026-02), in plain English.', current_date + 7),
('evergreen','carousel','{}','Day 9 -- 2011 Midwest outbreak -- scope vs coverage','Uses the 2011 tri-state Midwest hail/tornado outbreak era commercial-roof underpayment pattern to explain scope-vs-coverage gaps.', current_date + 8),
('evergreen','linkedin_post','{}','Day 10 -- Roof-life vs replacement-cost thinking','Roof-life vs. replacement-cost thinking -- soft intro to the ROI Calculator lead magnet.', current_date + 9),
('evergreen','comment','{}','Day 11 -- Comment prompts -- deferred roof maintenance','Two prompts for engaging on property-management LinkedIn groups about deferred roof maintenance.', current_date + 10),
('evergreen','linkedin_post','{TX}','Day 12 -- TX 27.02(b) boldface contract notice','TX Bus. and Com. Code Section 27.02(b) -- the boldface contract notice every insurance-proceeds contract needs.', current_date + 11),
('evergreen','carousel','{}','Day 13 -- Anatomy of a commercial roof estimate','Anatomy of a commercial roof estimate: tear-off, flashing, code-upgrade, depreciation -- what to check.', current_date + 12),
('evergreen','newsletter','{TX}','Day 14 -- Newsletter #1 -- 1970 Lubbock tornado and code upgrades','Anchors on the 1970 Lubbock, TX tornado rebuilding-code lessons -> how modern code-upgrade coverage traces back to post-disaster building-code reform.', current_date + 13),
('evergreen','linkedin_post','{OK}','Day 15 -- OK insurer response-time windows','OK 36 O.S. Section 3629/1250.7 insurer response-time windows explained for building owners.', current_date + 14),
('evergreen','video_script','{}','Day 16 -- What a hail-impact score means','45-sec explainer: what a hail-impact score is and how it''s calculated from public storm data.', current_date + 15),
('evergreen','carousel','{}','Day 17 -- Portfolio owners -- one storm, many properties','REIT/portfolio owners: why a single storm event can touch dozens of properties differently.', current_date + 16),
('evergreen','linkedin_post','{FL}','Day 18 -- FL pay-or-deny timeline shift','Florida''s shift from 90-day to 60-day pay-or-deny -- what it means for building owners'' planning timelines.', current_date + 17),
('evergreen','comment','{}','Day 19 -- Comment prompts -- NN-lease responsibilities','Two prompts for engaging on posts about NN-lease landlord responsibilities.', current_date + 18),
('evergreen','linkedin_post','{}','Day 20 -- Contractor documentation vs adjuster negotiation','The difference between a general contractor''s documentation role and a public adjuster''s negotiation role (Stonewater Roofing case, plain English).', current_date + 19),
('evergreen','video_script','{}','Day 21 -- 1938 Long Island hurricane vs modern hail data','Uses the 1938 Long Island Express hurricane (an era with no aerial imagery and largely lost records) to contrast with today''s satellite hail-swath data -- why claim readiness looks different now.', current_date + 20),
('evergreen','linkedin_post','{IL}','Day 22 -- IL deductible-fraud statute explained','IL 215 ILCS 5/155.51 deductible-fraud statute explained for property managers.', current_date + 21),
('evergreen','carousel','{}','Day 23 -- Pre-storm checklist for nonprofits','Religious/nonprofit building owners: a five-point pre-storm documentation checklist.', current_date + 22),
('evergreen','linkedin_post','{}','Day 24 -- Why deductible waivers are illegal','Why "we''ll waive your deductible" is illegal in every state we serve -- and what a compliant conversation sounds like instead.', current_date + 23),
('evergreen','newsletter','{}','Day 25 -- Newsletter -- storm activity and deadlines recap','Quarterly-style educational digest: recent storm activity + a reminder of state notice deadlines.', current_date + 24),
('evergreen','comment','{}','Day 26 -- Comment prompts -- shopping center and industrial owners','Two prompts for engaging on shopping-center / industrial ownership posts.', current_date + 25),
('evergreen','linkedin_post','{FL}','Day 27 -- Hurricane Andrew and FL building codes','Uses Hurricane Andrew (1992) to explain how it drove modern Florida building codes, connected to the SB 2-A deadline compression building owners face today.', current_date + 26),
('evergreen','carousel','{}','Day 28 -- Consent and TCPA -- why we ask first','Consent and communication: why Restoration GC asks before texting/calling, and what TCPA consent actually protects.', current_date + 27),
('evergreen','video_script','{}','Day 29 -- What happens after a Hail-Impact Report request','45-sec explainer: "What happens after you request a Hail-Impact Report."', current_date + 28),
('evergreen','linkedin_post','{}','Day 30 -- Recap -- the five lead magnets','Recap post: the five lead magnets, what each one does, and who they''re for.', current_date + 29);
