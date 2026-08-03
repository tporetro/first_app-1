#!/usr/bin/env python3
"""
RGV/McAllen Outbound Pipeline: Enrich (2-stage) -> Match -> Dial

Pipeline stage order (per MJ's spec):

1. Load a batch CSV (one of rgv_batch_001.csv ... rgv_batch_096.csv)
2a. RESOLVE ENTITY: for leads owned by an LLC/corp, run the
    "opensosdata-enrichment" Apify actor against the Owner Name to
    find the actual person behind the entity (via Secretary of State
    filings) -- registered agent / officer / member name.
2b. SKIP-TRACE: feed that resolved person's name into a second Apify
    actor to find their phone number.
3. MATCH each contactable lead to the nearest valid active job in
   active_jobs_cleaned.csv (see reference-street-matching-spec.md)
4. DIAL matched leads via Retell's Create Phone Call API, passing
   reference_street and other fields as retell_llm_dynamic_variables

This script does NOT run anything by default. It requires real API
credentials via environment variables, and defaults to --dry-run,
which exercises every stage except the three live network calls
(SOS resolution, skip-trace, Retell dial) so the logic can be
verified before it's allowed to touch real phone numbers.

=========================================================
REQUIRED ENVIRONMENT VARIABLES (set before running live)

APIFY_API_TOKEN          Your Apify API token (Apify Console -> Integrations)
APIFY_SOS_ACTOR_ID       e.g. "your-username~opensosdata-enrichment"
                         Stage 2a: Owner Name (LLC) -> resolved person name
APIFY_SKIPTRACE_ACTOR_ID e.g. "your-username~skip-trace-actor"
                         Stage 2b: resolved person name (+ property address)
                         -> phone number
RETELL_API_KEY           Your Retell API key
RETELL_AGENT_ID          The published agent ID for the RGV/McAllen "Alex" script
RETELL_FROM_NUMBER       E.164 formatted Retell-owned outbound number, e.g. +19565551234

=========================================================
!!! ACTION NEEDED BEFORE FIRST LIVE RUN !!!

I do not have visibility into the actual input/output schema of either
Apify actor. I've isolated every place that schema matters into four
functions, marked with "ADJUST TO YOUR ACTOR'S SCHEMA":
  - build_sos_input() / parse_sos_output()
    <- Stage 2a: how Owner Name is sent to the SOS actor, and how
       the resolved person's name is read back out
  - build_skiptrace_input() / parse_skiptrace_output()
    <- Stage 2b: how the resolved name (+ address) is sent to the
       skip-trace actor, and how the phone number is read back out

Open each actor in Apify Console -> Input/Output tab, confirm the real
field names, and edit those four functions to match. Everything else
in this script (matching, Retell payload, logging, batching) is
schema-independent and should not need changes.

NOTE on individually-owned properties: if Owner Name is already an
individual (not an LLC/corp), Stage 2a is skipped for that lead and it
goes straight to skip-trace on the owner name as given -- see
is_entity_owned() below, which uses a simple suffix heuristic (LLC,
INC, LP, LTD, CORP, CO, TRUST). Adjust that heuristic if it
misclassifies owners in your data.
"""

import argparse
import csv
import json
import math
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ---------------------------------------------------------
# Config
# ---------------------------------------------------------

APIFY_API_TOKEN = os.environ.get("APIFY_API_TOKEN", "")
APIFY_SOS_ACTOR_ID = os.environ.get("APIFY_SOS_ACTOR_ID", "")
APIFY_SKIPTRACE_ACTOR_ID = os.environ.get("APIFY_SKIPTRACE_ACTOR_ID", "")
RETELL_API_KEY = os.environ.get("RETELL_API_KEY", "")
RETELL_AGENT_ID = os.environ.get("RETELL_AGENT_ID", "")
RETELL_FROM_NUMBER = os.environ.get("RETELL_FROM_NUMBER", "")

# Substrings that mark an Owner Name as a BUSINESS ENTITY worth attempting
# SOS resolution on -- not just corporate suffixes (LLC/Inc/Corp), but also
# business-pattern words that show up on unsuffixed county tax-roll names
# for genuine registered businesses (banks, agencies, distributors, etc.).
# SOS resolution failing gracefully (no_match) is already handled downstream,
# so it's safer to attempt resolution here than to guess these are people.
ENTITY_MARKERS = ("LLC", "L L C", "INC", "CORP", "CORPORATION", "LP", "L P",
                   "LTD", "LIMITED", "TRUST", "TR ", "TRST", "LLP", "COMPANY",
                   "CO ", "PARTNERSHIP", "BANK", "CREDIT UNION", "ASSOCIATES",
                   "PROPERTIES", "DISTRIBUTORS", "AGENCY", "CENTERS", "CENTER",
                   "INSURANCE", "ASSOCIATION", "SOCIETY", "FOUNDATION", "GROUP",
                   "ENTERPRISES", "HOLDINGS", "INVESTMENTS", "REALTY",
                   "MANAGEMENT", "APARTMENTS")

# Owners that are government / school / religious-congregation bodies --
# no SOS filing resolves "the person behind" a county or a school district,
# and no skip-trace on the institution's name will find a decision-maker.
# These genuinely need a different research process (e.g. finding a
# facilities director by role, not by searching the entity's own name) and
# are excluded here rather than fed into name-based search, which would
# just produce garbage. Kept deliberately narrow -- only categories with no
# plausible SOS/skip-trace path -- everything else routes to ENTITY_MARKERS
# above and gets a real resolution attempt instead of being pre-excluded.
INSTITUTIONAL_MARKERS = ("COUNTY", "CISD", "C I S D", " ISD", "I S D",
                          "IND SCH", "SCHL DIST", "SCHOOL DIST", "SCHOOL",
                          "UNIVERSITY", "COLLEGE", "CHURCH", "IGLESIA",
                          "DIOCESE", "PARISH", "CONGREGATION", "ASSEMBLY",
                          "WORSHIP", "TEMPLE", "MHMR", "HOUSING AUTHORITY",
                          "CITY OF", "STATE OF", "BOARD OF REGENTS",
                          "HABILITATION", "GOVERNMENT", "FEDERAL",
                          "UNITED STATES", "BORDER PATROL", "ARMORY",
                          "NATIONAL GUARD", "CONFIDENTIAL")

# Owner names listing more than one person ("Powell Lance C & Kristin Vackar
# Mccollough") -- a naive first/last split would mangle these regardless of
# which bucket they land in. Flagged so downstream can decide how to handle
# rather than silently searching on a garbled name.
JOINT_OWNER_MARKERS = (" & ", " AND ")

APIFY_RUN_URL_TMPL = "https://api.apify.com/v2/acts/{actor_id}/runs?token={token}"
APIFY_RUN_STATUS_URL_TMPL = "https://api.apify.com/v2/actor-runs/{run_id}?token={token}"
APIFY_DATASET_URL_TMPL = "https://api.apify.com/v2/datasets/{dataset_id}/items?token={token}&format=json"
RETELL_CREATE_CALL_URL = "https://api.retellai.com/v2/create-phone-call"

# Matching parameters, per reference-street-matching-spec.md.
# Spec default is 1 mile, but MJ widened this to 6 miles for the live RGV
# campaign (see "Radius note" in docs/campaigns/rgv-mcallen/reference-job-matching-spec.md)
# after 1 mile matched only 4/69 leads. Kept in sync with that decision, and
# with lib/reference_street_campaign_runner.rb and the daily_reference_street_leads
# SQL view, which both already use 6 miles.
MATCH_RADIUS_MILES = 6.0
MAX_JOB_AGE_DAYS = 30

# Retell calls-per-second guardrail (be conservative; confirm your account's actual CPS limit)
RETELL_CALL_DELAY_SECONDS = 1.5

AUDIT_LOG_PATH = "pipeline_audit_log.csv"


# ---------------------------------------------------------
# Small HTTP helper (stdlib only, no extra dependencies)
# ---------------------------------------------------------

def http_request(url, method="GET", headers=None, body=None, timeout=310):
    headers = headers or {}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = {"raw_error": raw}
        return e.code, parsed


# ---------------------------------------------------------
# Stage 1: Load batch
# ---------------------------------------------------------

def load_batch(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


# ---------------------------------------------------------
# Stage 2: Apify enrichment
# ---------------------------------------------------------

def _normalize_owner_name(owner_name):
    """Strip punctuation noise (trailing commas, periods) so marker matching
    isn't defeated by formatting like 'Walmart Inc,' or 'Corp.'"""
    name_upper = (owner_name or "").upper().strip()
    for ch in (",", ".", "'"):
        name_upper = name_upper.replace(ch, "")
    return f" {name_upper} "  # pad so substring markers with leading/trailing space match cleanly


def is_institutional_owner(owner_name):
    """True if Owner Name is a government/school/religious/institutional body --
    not an LLC and not a searchable individual name. Checked BEFORE
    is_entity_owned() since some institutional names also contain words
    that could false-match entity markers."""
    padded = _normalize_owner_name(owner_name)
    return any(marker in padded for marker in INSTITUTIONAL_MARKERS)


def is_entity_owned(owner_name):
    """True if Owner Name looks like a registered business (LLC/corp/trust/
    bank/agency/etc) worth attempting SOS resolution on. Only call this
    after ruling out is_institutional_owner()."""
    padded = _normalize_owner_name(owner_name)
    return any(marker in padded for marker in ENTITY_MARKERS)


def is_joint_owner(owner_name):
    """True if the Owner Name lists more than one person (e.g. spouses,
    co-owners) -- needs special-cased name handling, not a naive split."""
    padded = _normalize_owner_name(owner_name)
    return any(marker in padded for marker in JOINT_OWNER_MARKERS)


def run_apify_actor(actor_id, actor_input):
    """Generic: start an Apify actor run async, poll for completion, return dataset items."""
    run_url = APIFY_RUN_URL_TMPL.format(actor_id=actor_id, token=APIFY_API_TOKEN)
    status, run_resp = http_request(run_url, method="POST", body=actor_input)
    if status not in (200, 201):
        raise RuntimeError(f"Apify run start failed for {actor_id} ({status}): {run_resp}")

    run_id = run_resp["data"]["id"]
    dataset_id = run_resp["data"]["defaultDatasetId"]

    status_url = APIFY_RUN_STATUS_URL_TMPL.format(run_id=run_id, token=APIFY_API_TOKEN)
    terminal_statuses = {"SUCCEEDED", "FAILED", "ABORTED", "TIMED-OUT"}
    poll_interval = 5
    max_wait_seconds = 600
    waited = 0
    while waited < max_wait_seconds:
        s, resp = http_request(status_url, method="GET")
        run_status = resp.get("data", {}).get("status", "")
        if run_status in terminal_statuses:
            if run_status != "SUCCEEDED":
                raise RuntimeError(f"Apify run {run_id} ({actor_id}) ended with status {run_status}: {resp}")
            break
        time.sleep(poll_interval)
        waited += poll_interval
    else:
        raise RuntimeError(f"Apify run {run_id} ({actor_id}) did not finish within {max_wait_seconds}s")

    dataset_url = APIFY_DATASET_URL_TMPL.format(dataset_id=dataset_id, token=APIFY_API_TOKEN)
    s, items = http_request(dataset_url, method="GET")
    if not isinstance(items, list):
        raise RuntimeError(f"Unexpected dataset response shape from {actor_id}: {items}")
    return items


# -- Stage 2a: SOS entity resolution (LLC/corp -> person) --------------

def build_sos_input(entity_leads):
    """
    ADJUST TO YOUR ACTOR'S SCHEMA.

    Packages leads with an entity Owner Name for the opensosdata actor.
    Only leads where is_entity_owned() is True should reach this function.
    """
    return {
        "lookups": [
            {
                "account_id": row.get("Account ID", ""),
                "entity_name": row.get("Owner Name", ""),
                "state": "TX",
            }
            for row in entity_leads
        ]
    }


def parse_sos_output(dataset_items):
    """
    ADJUST TO YOUR ACTOR'S SCHEMA.

    Expected fields per item: account_id, resolved_person_first_name,
    resolved_person_last_name. Returns dict keyed by account_id.
    Adjust field names to match what the actor actually returns
    (e.g. it may return "registered_agent_name" as a single string
    rather than split first/last -- split it here if so).
    """
    resolved = {}
    for item in dataset_items:
        acct_id = str(item.get("account_id", ""))
        if acct_id:
            resolved[acct_id] = {
                "resolved_first_name": item.get("resolved_person_first_name", ""),
                "resolved_last_name": item.get("resolved_person_last_name", ""),
            }
    return resolved


# -- Stage 2b: skip-trace (person name -> phone) ------------------------

def build_skiptrace_input(leads_with_names):
    """
    ADJUST TO YOUR ACTOR'S SCHEMA.

    leads_with_names: rows that already have a person name to search on,
    either the original Owner Name (individual owner) or a name resolved
    in Stage 2a (entity owner). Property address included to help the
    skip-trace actor disambiguate common names.
    """
    return {
        "searches": [
            {
                "account_id": row.get("Account ID", ""),
                "first_name": row.get("_search_first_name", ""),
                "last_name": row.get("_search_last_name", ""),
                "property_address": row.get("Property Address", ""),
                "city": row.get("City", ""),
                "state": "TX",
            }
            for row in leads_with_names
        ]
    }


def parse_skiptrace_output(dataset_items):
    """
    ADJUST TO YOUR ACTOR'S SCHEMA.

    Expected fields per item: account_id, phone, email (optional).
    Returns dict keyed by account_id.
    """
    results = {}
    for item in dataset_items:
        acct_id = str(item.get("account_id", ""))
        if acct_id:
            results[acct_id] = {
                "contact_phone": item.get("phone", ""),
                "contact_email": item.get("email", ""),
            }
    return results


def run_two_stage_enrichment(batch_rows, dry_run):
    """
    Runs Stage 2a (SOS resolution, entity-owned leads only) then Stage 2b
    (skip-trace, all leads) and merges results back onto batch_rows.
    """
    if dry_run:
        merged = []
        for row in batch_rows:
            r = dict(row)
            r["_search_first_name"] = ""
            r["_search_last_name"] = ""
            r["contact_first_name"] = ""
            r["contact_last_name"] = ""
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = "dry_run_not_enriched"
            merged.append(r)
        return merged

    if not APIFY_API_TOKEN or not APIFY_SOS_ACTOR_ID or not APIFY_SKIPTRACE_ACTOR_ID:
        raise RuntimeError(
            "APIFY_API_TOKEN, APIFY_SOS_ACTOR_ID, and APIFY_SKIPTRACE_ACTOR_ID must "
            "be set for a live run. Use --dry-run to test pipeline logic without credentials."
        )

    # Three-way split: institutional owners are excluded outright (see
    # INSTITUTIONAL_MARKERS docstring above -- SOS resolution and name-based
    # skip-trace both produce garbage for a school district or county).
    # Check institutional FIRST, since some institutional names also contain
    # entity-like words (e.g. "Trust" appearing in a church name).
    institutional_leads = []
    entity_leads = []
    individual_leads = []
    for row in batch_rows:
        owner = row.get("Owner Name", "")
        if is_institutional_owner(owner):
            institutional_leads.append(row)
        elif is_entity_owned(owner):
            entity_leads.append(row)
        else:
            individual_leads.append(row)

    entity_account_ids = {r.get("Account ID") for r in entity_leads}

    # Stage 2a: resolve entities to people
    sos_resolved = {}
    if entity_leads:
        sos_input = build_sos_input(entity_leads)
        sos_items = run_apify_actor(APIFY_SOS_ACTOR_ID, sos_input)
        sos_resolved = parse_sos_output(sos_items)

    # Attach the name to search on for every non-institutional lead
    prepped = []
    for row in batch_rows:
        r = dict(row)
        acct_id = str(row.get("Account ID", ""))

        if row in institutional_leads:
            r["_search_first_name"] = ""
            r["_search_last_name"] = ""
            r["_sos_resolved"] = "not_applicable_institutional_owner"
            prepped.append(r)
            continue

        if row.get("Account ID") in entity_account_ids:
            resolution = sos_resolved.get(acct_id)
            if resolution:
                r["_search_first_name"] = resolution["resolved_first_name"]
                r["_search_last_name"] = resolution["resolved_last_name"]
                r["_sos_resolved"] = "yes"
            else:
                r["_search_first_name"] = ""
                r["_search_last_name"] = ""
                r["_sos_resolved"] = "no_match"
        elif is_joint_owner(row.get("Owner Name", "")):
            # Two+ people listed together -- take only the first-listed
            # person for the search rather than mangling both names
            # together. Flagged so downstream knows a co-owner exists
            # and wasn't searched.
            owner_raw = row.get("Owner Name", "") or ""
            first_person = owner_raw.split("&")[0].split(" AND ")[0].strip()
            parts = first_person.split()
            r["_search_first_name"] = parts[0] if parts else ""
            r["_search_last_name"] = parts[-1] if len(parts) > 1 else ""
            r["_sos_resolved"] = "not_applicable_joint_owner_first_listed_only"
        else:
            # individual owner -- split Owner Name as a naive first/last guess
            parts = (row.get("Owner Name", "") or "").split()
            r["_search_first_name"] = parts[0] if parts else ""
            r["_search_last_name"] = parts[-1] if len(parts) > 1 else ""
            r["_sos_resolved"] = "not_applicable_individual_owner"
        prepped.append(r)

    # Stage 2b: skip-trace everyone who has a name to search on
    skiptrace_candidates = [r for r in prepped if r.get("_search_first_name") or r.get("_search_last_name")]
    skiptrace_results = {}
    if skiptrace_candidates:
        skiptrace_input = build_skiptrace_input(skiptrace_candidates)
        skiptrace_items = run_apify_actor(APIFY_SKIPTRACE_ACTOR_ID, skiptrace_input)
        skiptrace_results = parse_skiptrace_output(skiptrace_items)

    merged = []
    for r in prepped:
        acct_id = str(r.get("Account ID", ""))
        contact = skiptrace_results.get(acct_id)
        r["contact_first_name"] = r.get("_search_first_name", "")
        r["contact_last_name"] = r.get("_search_last_name", "")
        if r.get("_sos_resolved") == "not_applicable_institutional_owner":
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = "excluded_institutional_owner"
        elif contact and contact.get("contact_phone"):
            r["contact_phone"] = contact["contact_phone"]
            r["contact_email"] = contact.get("contact_email", "")
            r["enrichment_status"] = "matched"
        elif r.get("_sos_resolved") == "no_match":
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = "sos_resolution_failed"
        else:
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = "skiptrace_no_match"
        merged.append(r)

    return merged


# ---------------------------------------------------------
# Stage 3: Match to active jobs
# ---------------------------------------------------------

def haversine_miles(lat1, lon1, lat2, lon2):
    R = 3958.8  # Earth radius in miles
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return 2 * R * math.asin(math.sqrt(a))


def load_active_jobs(path):
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    eligible = [r for r in rows if str(r.get("pipeline_ready", "")).strip().lower() == "true"]
    return eligible


def match_lead_to_job(lead, active_jobs):
    """
    Returns the nearest eligible job within MATCH_RADIUS_MILES, or None.
    Per the matching spec: no match => lead is excluded from this campaign,
    never falls back to a farther or stale job.
    """
    try:
        lead_lat = float(lead.get("Prop Lat", ""))
        lead_lon = float(lead.get("Prop Lon", ""))
    except (ValueError, TypeError):
        return None

    best_job = None
    best_dist = None
    for job in active_jobs:
        try:
            job_lat = float(job["latitude"])
            job_lon = float(job["longitude"])
        except (ValueError, TypeError, KeyError):
            continue
        dist = haversine_miles(lead_lat, lead_lon, job_lat, job_lon)
        if dist <= MATCH_RADIUS_MILES and (best_dist is None or dist < best_dist):
            best_dist = dist
            best_job = job

    return best_job


# ---------------------------------------------------------
# Stage 4: Dial via Retell
# ---------------------------------------------------------

def normalize_phone_e164(raw_phone):
    """Best-effort US phone normalization to E.164. Returns None if unusable."""
    digits = "".join(c for c in str(raw_phone) if c.isdigit())
    if len(digits) == 10:
        return f"+1{digits}"
    if len(digits) == 11 and digits.startswith("1"):
        return f"+{digits}"
    return None


def build_retell_payload(lead, matched_job):
    to_number = normalize_phone_e164(lead.get("contact_phone", ""))
    if not to_number:
        return None

    dynamic_vars = {
        "address_raw_best": lead.get("Property Address", "") or "",
        "city": lead.get("City", "") or "",
        "state": "TX",
        "first_name": lead.get("contact_first_name", "") or "",
        "last_name": lead.get("contact_last_name", "") or "",
        "call_attempt": "1",
        "reference_street": matched_job.get("reference_street", "") if matched_job else "",
    }
    # Retell requires all dynamic variable values to be strings
    dynamic_vars = {k: str(v) for k, v in dynamic_vars.items()}

    return {
        "from_number": RETELL_FROM_NUMBER,
        "to_number": to_number,
        "override_agent_id": RETELL_AGENT_ID,
        "retell_llm_dynamic_variables": dynamic_vars,
        "metadata": {
            "account_id": lead.get("Account ID", ""),
            "matched_job_id": matched_job.get("Job ID", "") if matched_job else "",
            "batch_id": lead.get("batch_id", ""),
        },
    }


def place_call(payload, dry_run):
    if dry_run:
        return {"call_id": "DRY_RUN_NO_CALL_PLACED", "call_status": "dry_run"}

    if not RETELL_API_KEY or not RETELL_FROM_NUMBER or not RETELL_AGENT_ID:
        raise RuntimeError(
            "RETELL_API_KEY, RETELL_FROM_NUMBER, and RETELL_AGENT_ID must be set for a live run."
        )

    headers = {"Authorization": f"Bearer {RETELL_API_KEY}"}
    status, resp = http_request(RETELL_CREATE_CALL_URL, method="POST", headers=headers, body=payload)
    if status not in (200, 201):
        raise RuntimeError(f"Retell call creation failed ({status}): {resp}")
    return resp


# ---------------------------------------------------------
# Audit logging
# ---------------------------------------------------------

def append_audit_row(row, first_write):
    mode = "w" if first_write else "a"
    with open(AUDIT_LOG_PATH, mode, newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(row.keys()))
        if first_write:
            writer.writeheader()
        writer.writerow(row)


# ---------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------

def process_batch(batch_path, active_jobs_path, dry_run, audit_first_write):
    print(f"\n=== Processing {batch_path} (dry_run={dry_run}) ===")
    batch_rows = load_batch(batch_path)
    print(f"  Loaded {len(batch_rows)} leads")

    active_jobs = load_active_jobs(active_jobs_path)
    print(f"  Loaded {len(active_jobs)} pipeline-ready active jobs for matching")

    enriched = run_two_stage_enrichment(batch_rows, dry_run=dry_run)
    enriched_count = sum(1 for r in enriched if r["enrichment_status"] == "matched")
    sos_failed = sum(1 for r in enriched if r["enrichment_status"] == "sos_resolution_failed")
    skiptrace_failed = sum(1 for r in enriched if r["enrichment_status"] == "skiptrace_no_match")
    print(f"  Enrichment: {enriched_count}/{len(enriched)} leads got a phone number")
    if not dry_run:
        print(f"    (SOS resolution failed: {sos_failed}, skip-trace no match: {skiptrace_failed})")

    results = {
        "excluded_no_contact": 0,
        "excluded_no_job_match": 0,
        "excluded_bad_phone_format": 0,
        "called": 0,
        "errors": 0,
    }

    first_write = audit_first_write
    for lead in enriched:
        base_audit = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "batch_id": lead.get("batch_id", ""),
            "account_id": lead.get("Account ID", ""),
            "property_address": lead.get("Property Address", ""),
            "city": lead.get("City", ""),
        }

        if lead["enrichment_status"] != "matched" or not lead.get("contact_phone"):
            results["excluded_no_contact"] += 1
            append_audit_row({**base_audit, "outcome": "excluded_no_contact_info",
                               "matched_job_id": "", "call_id": ""}, first_write)
            first_write = False
            continue

        matched_job = match_lead_to_job(lead, active_jobs)
        if not matched_job:
            results["excluded_no_job_match"] += 1
            append_audit_row({**base_audit, "outcome": "excluded_no_nearby_active_job",
                               "matched_job_id": "", "call_id": ""}, first_write)
            first_write = False
            continue

        payload = build_retell_payload(lead, matched_job)
        if payload is None:
            results["excluded_bad_phone_format"] += 1
            append_audit_row({**base_audit, "outcome": "excluded_unparseable_phone",
                               "matched_job_id": matched_job.get("Job ID", ""), "call_id": ""}, first_write)
            first_write = False
            continue

        try:
            call_resp = place_call(payload, dry_run=dry_run)
            results["called"] += 1
            append_audit_row({**base_audit, "outcome": "call_placed" if not dry_run else "dry_run_would_call",
                               "matched_job_id": matched_job.get("Job ID", ""),
                               "call_id": call_resp.get("call_id", "")}, first_write)
            first_write = False
        except Exception as e:
            results["errors"] += 1
            append_audit_row({**base_audit, "outcome": f"error: {e}",
                               "matched_job_id": matched_job.get("Job ID", ""), "call_id": ""}, first_write)
            first_write = False

        if not dry_run:
            time.sleep(RETELL_CALL_DELAY_SECONDS)

    print(f"  Results: {results}")
    return results, first_write


def main():
    parser = argparse.ArgumentParser(description="RGV/McAllen enrich -> match -> dial pipeline")
    parser.add_argument("batches", nargs="+", help="Path(s) to batch CSV file(s), or a directory of them")
    parser.add_argument("--active-jobs", default="active_jobs_cleaned.csv",
                         help="Path to the cleaned active jobs CSV (pipeline_ready column required)")
    parser.add_argument("--live", action="store_true",
                         help="Actually call Apify and Retell. Without this flag, runs in --dry-run mode.")
    args = parser.parse_args()

    dry_run = not args.live

    if dry_run:
        print("=" * 70)
        print("DRY RUN MODE -- no real Apify or Retell calls will be made.")
        print("Pass --live once credentials are set and you've reviewed the")
        print("audit log from a dry run.")
        print("=" * 70)
    else:
        print("=" * 70)
        print("!!! LIVE MODE -- this will place real outbound phone calls. !!!")
        print("=" * 70)
        confirm = input("Type YES to proceed: ")
        if confirm.strip() != "YES":
            print("Aborted.")
            sys.exit(0)

    # Expand any directories passed in
    batch_files = []
    for path in args.batches:
        if os.path.isdir(path):
            batch_files.extend(
                sorted(os.path.join(path, f) for f in os.listdir(path)
                       if f.startswith("rgv_batch_") and f.endswith(".csv"))
            )
        else:
            batch_files.append(path)

    audit_first_write = not os.path.exists(AUDIT_LOG_PATH)
    totals = {"excluded_no_contact": 0, "excluded_no_job_match": 0,
              "excluded_bad_phone_format": 0, "called": 0, "errors": 0}

    for batch_path in batch_files:
        results, audit_first_write = process_batch(
            batch_path, args.active_jobs, dry_run, audit_first_write
        )
        for k in totals:
            totals[k] += results[k]

    print("\n" + "=" * 70)
    print(f"ALL BATCHES COMPLETE. Totals: {totals}")
    print(f"Audit log written to: {AUDIT_LOG_PATH}")
    print("=" * 70)


if __name__ == "__main__":
    main()
