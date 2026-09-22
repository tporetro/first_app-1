#!/usr/bin/env python3
"""
Reference implementation of the Compliance-Gate Agent's DETERMINISTIC rule
matching (banned-phrase regex + required-disclaimer presence), run against
the 44 fixtures in compliance_redteam.md and the live compliance_rules table.

Scope and honesty note: the production Compliance-Gate Agent
(04-agents/compliance_gate.md) is an LLM (GPT-4o per 03-n8n/W3), which also
composes the actual `rewrite` text and can catch violations no regex would.
This script does NOT call that LLM — it has no OpenAI credential in this
session. What it DOES verify, for real, against the actual seeded lexicon:
whether the regex patterns and required-disclaimer strings a human/LLM
would also rely on actually fire (or correctly don't fire) on each fixture.
A bug at this layer would let something slip past the LLM gate too, since
the LLM is checking the same underlying rule set. This is a necessary,
not sufficient, condition for "a clean red-team run."

Usage:
    export SUPABASE_URL=... SUPABASE_SERVICE_KEY=...   # or SUPABASE_ANON_KEY, read-only
    python3 run_redteam.py
"""
import json
import os
import re
import sys
import urllib.request

# --------------------------------------------------------------------------
# 44 fixtures transcribed from compliance_redteam.md. Scenario-description
# rows (e.g. "TX contract missing the notice") are expanded into literal
# representative draft text so the engine has something concrete to check.
# --------------------------------------------------------------------------
FIXTURES = [
    # A. Universal banned-phrase tests
    (1, "We guarantee full payout on your claim", [], "rewrite"),
    (2, "100% of homeowners who work with us get paid in full", [], "rewrite"),
    (3, "You have a strong bad-faith lawsuit against your insurer", [], "rewrite"),
    (4, "We will file suit for you if they deny the claim", [], "rewrite"),
    (5, "We negotiate directly with your insurer to maximize your settlement", [], "rewrite"),
    (6, "We act as your adjuster throughout the process", [], "rewrite"),
    # B. Texas-specific
    (7, "We'll waive your deductible in Texas", ["TX"], "rewrite"),
    (8, "No deductible, no out-of-pocket cost -- free roof!", ["TX"], "rewrite"),
    (9, "We'll cover your deductible so you pay nothing", ["TX"], "rewrite"),
    (10, "This agreement is for roof repair services totaling $1,200, expected to be paid from your property insurance claim proceeds. Payment is due upon completion of work.", ["TX"], "flag"),
    (11, "After a hailstorm, here's what Texas building owners should document before filing a claim: photos, your date of loss, and your policy declarations page.", ["TX"], "flag"),
    (12, "A hailstorm passed through your area. Texas law requires you to pay your deductible (Tex. Ins. Code §707.002); we help you plan for it. Restoration GC is a licensed general contractor, not a public insurance adjuster, and does not adjust claims or provide legal advice (Tex. Ins. Code §4102.163).", ["TX"], "pass"),
    # C. Oklahoma-specific
    (13, "We'll eat the deductible for you", ["OK"], "rewrite"),
    (14, "We'll pay your deductible so the repair is free", ["OK"], "rewrite"),
    (15, "Your roof replacement estimate: $18,400 total, covering tear-off, underlayment, and shingle replacement.", ["OK"], "flag"),
    (16, "After the recent hailstorm, here is your estimate. Oklahoma law (59 O.S. §1151.30) requires this written notification: a roofing contractor may not pay any part of your deductible.", ["OK"], "pass"),
    # D. Florida-specific
    (17, "We guarantee your Florida claim gets approved", ["FL"], "rewrite"),
    (18, "If your Florida property was damaged by the recent storm, you can file a new claim with your insurer.", ["FL"], "flag"),
    (19, "In Florida, notice of a new or reopened property claim is generally barred after 1 year from the date of loss (Fla. Stat. §627.70132). If your property was affected, act soon.", ["FL"], "pass"),
    # E. Illinois-specific
    (20, "Our public adjuster will handle everything for you", ["IL"], "rewrite"),
    (21, "We offer a paid referral to a licensed public adjuster", ["IL"], "rewrite"),
    (22, "We'll waive your deductible on this Illinois claim", ["IL"], "rewrite"),
    (23, "We can absorb part of your deductible", ["IL"], "rewrite"),
    (24, "We'll inflate the estimate to cover your deductible", ["IL"], "rewrite"),
    (25, "Restoration GC documents storm damage for Illinois property owners. We do not refer or pay for public adjuster services, and we don't waive deductibles.", ["IL"], "pass"),
    # F. Cross-state / combined
    (26, "We guarantee we'll get you paid and we'll waive your Texas deductible", ["TX"], "rewrite"),
    (27, "Our public adjuster will negotiate your Illinois claim and waive the deductible", ["IL"], "rewrite"),
    (28, "We act as your adjuster and guarantee full payout", ["OK"], "rewrite"),
    (29, "We'll eat the Oklahoma deductible and guarantee 100% payout", ["OK"], "rewrite"),
    # G. Clean-pass controls
    (30, "Restoration GC documents storm damage and coordinates inspections. We are a licensed general contractor, not a public adjuster, and do not adjust claims or provide legal advice.", [], "pass"),
    (31, "Here's what to check after a hailstorm: dated photos, your date of loss, and your full policy declarations page.", [], "pass"),
    (32, "Texas law requires you to pay your deductible (Tex. Ins. Code §707.002); we help you plan for it. Restoration GC is a licensed general contractor, not a public insurance adjuster, and does not adjust claims or provide legal advice (Tex. Ins. Code §4102.163).", ["TX"], "pass"),
    (33, "In Florida, notice of a new or reopened property claim is generally barred after 1 year from the date of loss (Fla. Stat. §627.70132).", ["FL"], "pass"),
    (34, "Oklahoma law (59 O.S. §1151.30) requires this written notification: a roofing contractor may not pay any part of your deductible.", ["OK"], "pass"),
    (35, "Illinois law (215 ILCS 5/155.51) prohibits waiving or inflating deductibles. We document damage only.", ["IL"], "pass"),
    (36, "These figures are for planning discussion only -- they don't reflect any insurance-claim value.", [], "pass"),
    # H. Required-disclaimer / missing-notice edge cases
    (37, "A hailstorm just hit the Austin metro. If your commercial roof was in the path, now's the time to document the damage.", ["TX"], "flag"),
    (38, "This month, we're covering what Florida commercial property owners need to know about filing claims after storm damage.", ["FL"], "flag"),
    (39, "Estimate for roof replacement services. Total: $22,750. Scope includes tear-off and underlayment replacement.", ["OK"], "flag"),
    (40, "Contract for roof replacement services, total cost $1,500, to be paid from insurance proceeds.", ["TX"], "flag"),
    # I. Near-miss / false-positive controls
    (41, "We guarantee we'll show up on time for your inspection", [], "rewrite"),
    (42, "Ask your independent public adjuster about code-upgrade coverage", ["IL"], "pass"),
    (43, "Your policy's deductible amount is listed on your declarations page", [], "pass"),
    (44, "A licensed public adjuster or attorney can advise you on legal options", [], "pass"),
]


def fetch_rules():
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/compliance_rules"
    key = os.environ.get("SUPABASE_SERVICE_KEY") or os.environ["SUPABASE_ANON_KEY"]
    req = urllib.request.Request(url + "?active=eq.true&select=*", headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def evaluate(draft: str, state_tags: list[str], rules: list[dict]) -> tuple[str, list[str]]:
    # applies_to='contract' rules (currently just tx_contract_notice) are never checked here:
    # content_drafts holds marketing content, never actual signed contracts (those go through
    # DocuSign per the top-level README) -- see 09-docs/risk_register.md for the finding.
    applicable = [
        r for r in rules
        if r.get("applies_to", "content") == "content" and (r["scope_state"] == "OTHER" or r["scope_state"] in state_tags)
    ]
    pattern_hits = []
    missing_disclaimers = []
    for r in applicable:
        if r["rule_type"] == "pattern":
            flags = re.IGNORECASE if r["is_regex"] else 0
            if r["is_regex"]:
                if re.search(r["pattern"], draft, flags):
                    pattern_hits.append(r["rule_key"])
            elif r["pattern"].lower() in draft.lower():
                pattern_hits.append(r["rule_key"])
        elif r["rule_type"] == "required_disclaimer":
            if r["pattern"] not in draft:
                missing_disclaimers.append(r["rule_key"])
    if pattern_hits:
        return "rewrite", pattern_hits
    if missing_disclaimers:
        return "flag", missing_disclaimers
    return "pass", []


def main() -> int:
    try:
        rules = fetch_rules()
    except KeyError as e:
        print(f"ERROR: set SUPABASE_URL and SUPABASE_SERVICE_KEY (or SUPABASE_ANON_KEY): missing {e}", file=sys.stderr)
        return 1

    print(f"Loaded {len(rules)} active rules from the live compliance_rules table.\n")

    failures = []
    block_severity_passes = []
    for num, draft, state_tags, expected in FIXTURES:
        actual, matched = evaluate(draft, state_tags, rules)
        ok = actual == expected
        marker = "OK  " if ok else "FAIL"
        print(f"[{marker}] #{num:>2} expected={expected:<8} actual={actual:<8} matched={matched}")
        if not ok:
            failures.append((num, expected, actual, matched, draft))
        if actual == "pass":
            applicable = [
                r for r in rules
                if r.get("applies_to", "content") == "content" and (r["scope_state"] == "OTHER" or r["scope_state"] in state_tags)
            ]
            for r in applicable:
                if r["severity"] == "block" and r["rule_type"] == "pattern":
                    if re.search(r["pattern"], draft, re.IGNORECASE):
                        block_severity_passes.append((num, r["rule_key"]))

    print(f"\n{len(FIXTURES) - len(failures)}/{len(FIXTURES)} fixtures matched their expected status.")
    print(f"Block-severity-match-marked-pass invariant violations: {len(block_severity_passes)}")

    if failures:
        print("\nFAILURES:")
        for num, expected, actual, matched, draft in failures:
            print(f"  #{num}: expected {expected}, got {actual} (matched: {matched}) -- {draft!r}")

    return 1 if (failures or block_severity_passes) else 0


if __name__ == "__main__":
    raise SystemExit(main())
