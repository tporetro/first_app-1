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

def http_request(url, method="GET", headers=None, body=None, timeout=310, retry_on_network_error=True):
    """
    retry_on_network_error retries transient failures (connection reset,
    timeout -- NOT HTTPError, which is a real server response) up to 3 times
    with backoff. Found necessary live: a single "Connection reset by peer"
    on a GET status-poll crashed an entire in-progress batch with no
    recovery. Left as an explicit opt-out (not opt-in) because most calls
    here are safe to retry (GETs, Apify run-start -- a duplicate run just
    costs a few cents) -- EXCEPT Retell's create-phone-call: if that POST's
    response is lost to a network error, we can't tell whether the call was
    actually placed server-side, so blindly retrying risks dialing the same
    person twice. See place_call(), which passes retry_on_network_error=False.
    """
    headers = headers or {}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")

    attempts = 3 if retry_on_network_error else 1
    for attempt in range(1, attempts + 1):
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
        except urllib.error.URLError:
            if attempt == attempts:
                raise
            time.sleep(2 ** attempt)  # 2s, 4s


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
#
# VERIFIED against the real clawdeus/tx-biz-lookup actor (2026-08-03, via
# live test calls -- see docs/campaigns/rgv-mcallen/n8n-pipeline.md history).
# This actor takes ONE searchQuery per run (no batch/array input despite the
# original script's assumption) and does not echo back a caller-supplied
# correlation ID, so Stage 2a calls it once per entity-owned lead.
#
# Titles that plausibly indicate "the actual person who'd answer about this
# property," ranked by preference. Falls back to the first listed officer
# if none of these titles are present (e.g. a flat officer list with no
# clear hierarchy) -- better than no name, but tag it as such downstream.
SOS_PREFERRED_TITLES = ("PRESIDENT", "OWNER", "MEMBER", "MANAGER", "MANAGING")

# Found via live testing (2026-08-03): the actor does near-exact matching on
# searchQuery, and county tax-roll "Owner Name" strings rarely match the exact
# SOS-registered legal name -- e.g. "STORE MASTER FUNDING III LLC" -> 0
# results, but "STORE MASTER FUNDING" -> 10. Stripping the corporate suffix
# surfaces candidates, but a bare prefix like "SECURCARE" can return many
# unrelated entities (and the actor caps results at 10, so the real one isn't
# guaranteed to be among them) -- so candidates must pass _is_confident_match
# against the original full name, rather than blindly taking the first result.
CORPORATE_SUFFIX_WORDS = {
    "LLC", "LLP", "LP", "LTD", "LIMITED", "INC", "INCORPORATED", "CORP",
    "CORPORATION", "CO", "COMPANY", "TRUST", "TR", "PARTNERSHIP",
}


def _strip_corporate_suffix(name):
    """Drops trailing corporate-suffix tokens (LLC, LP, INC, ...) one at a
    time from the end, e.g. "STORE MASTER FUNDING III LLC" -> "STORE MASTER
    FUNDING III" -> ... Returns the shortest meaningful prefix, or the
    original name if it has no recognized suffix to strip."""
    tokens = (name or "").upper().replace(",", "").replace(".", "").split()
    while tokens and tokens[-1] in CORPORATE_SUFFIX_WORDS:
        tokens.pop()
    stripped = " ".join(tokens)
    return stripped or name


def _name_tokens(name):
    return set((name or "").upper().replace(",", "").replace(".", "").split()) - CORPORATE_SUFFIX_WORDS


def _is_confident_match(original_name, candidate_business_name):
    """
    Every meaningful word from the original (CAD) name must appear in the
    candidate's business name -- strict containment, not a similarity score.

    Two approaches were tried and rejected before this one:
    - difflib.SequenceMatcher (character-level): scored "SECURCARE MOVEIT
      MCALLEN LLC" vs "SECURCARE PROPERTIES I, LLC" at 0.66 purely from the
      shared "SECURCARE...LLC" prefix/suffix, letting a wrong entity through
      even though the distinguishing words (MOVEIT MCALLEN vs PROPERTIES I)
      share nothing.
    - Jaccard word overlap with a threshold: still fooled by near-miss series
      names, e.g. "...FUNDING III LLC" vs "...FUNDING IV LLC" share 3 of 4
      tokens (0.6 Jaccard) despite being different entities in a numbered
      series -- a plausible real pattern in this dataset (SecurCare itself
      has "PROPERTIES I/II/III/X" as distinct filings).

    Containment fixes both: MOVEIT/MCALLEN are absent from every SecurCare
    candidate -> correctly rejected. "III" is a real, required token that a
    "IV" candidate doesn't contain -> correctly rejected. Costs recall (a
    candidate with genuinely extra/reordered words that still IS the right
    entity could be missed) in exchange for not calling the wrong person.
    """
    orig_tokens = _name_tokens(original_name)
    cand_tokens = _name_tokens(candidate_business_name)
    if not orig_tokens or not cand_tokens:
        return False
    return orig_tokens.issubset(cand_tokens)


def build_sos_input(search_query):
    """ADJUST TO YOUR ACTOR'S SCHEMA. Verified: single searchQuery per run."""
    return {"searchQuery": search_query}


def sos_search_entity(owner_name, run_actor_fn):
    """
    Two-pass SOS search: try the full Owner Name first (works for entities
    whose CAD name matches their SOS filing exactly), then fall back to a
    corporate-suffix-stripped search if that returns nothing. Every
    candidate returned by either pass must pass _is_confident_match against
    the ORIGINAL owner name (not the stripped query) so a loose fallback
    search doesn't let a wrong entity through.

    run_actor_fn: callable(search_query) -> dataset_items, so this stays
    testable without hitting the network (see run_apify_actor call site).

    Returns the shortest confidently-matching entity dict (least likely to
    be padded with unrelated extra words), or None if nothing qualifies.
    """
    items = run_actor_fn(owner_name)
    stripped = _strip_corporate_suffix(owner_name)
    if not items and stripped != owner_name.upper().strip():
        items = run_actor_fn(stripped)
    if not items:
        return None

    confident = [i for i in items if _is_confident_match(owner_name, i.get("businessName"))]
    if not confident:
        return None
    return min(confident, key=lambda i: len(_name_tokens(i.get("businessName"))))


def parse_sos_output(entity):
    """
    ADJUST TO YOUR ACTOR'S SCHEMA.

    Verified real shape: an entity record has an "officers" list of
    {"AGNT_NM": "FULL NAME", "AGNT_TITL_TX": "TITLE", ...}. AGNT_NM is one
    string, not split first/last -- split it here. "registeredAgentName" is
    often a corporate registered-agent SERVICE (e.g. "CT CORPORATION
    SYSTEM"), not a person -- do not use it as a name.

    Found via live testing: some "officers" are themselves corporate/LP
    entities acting as general partner or governing member (e.g. "16031
    PARTNERS LTD"'s officer is "ASG CORP.", title "GENERAL PA[RTNER]") --
    common in layered commercial real estate ownership. Skip-tracing a
    corporate name as if it were a person is wrong, so those are filtered
    out via is_entity_owned/is_institutional_owner before picking a "best"
    officer -- if EVERY officer on file is itself a corporate entity, this
    correctly returns no match rather than a nonsense person search.

    Takes a single already-selected entity dict (see sos_search_entity
    above, which handles picking the right one out of a search's results).
    Returns (first_name, last_name, title) for the best-guess officer, or
    (None, None, None) if no entity/no individual officers found.
    """
    if not entity:
        return None, None, None
    officers = entity.get("officers") or []
    individual_officers = [
        o for o in officers
        if (o.get("AGNT_NM") or "").strip()
        and not is_entity_owned(o.get("AGNT_NM"))
        and not is_institutional_owner(o.get("AGNT_NM"))
    ]
    if not individual_officers:
        return None, None, None

    chosen = next(
        (o for o in individual_officers if any(t in (o.get("AGNT_TITL_TX") or "").upper() for t in SOS_PREFERRED_TITLES)),
        individual_officers[0],
    )
    full_name = (chosen.get("AGNT_NM") or "").strip()
    if not full_name:
        return None, None, None
    parts = full_name.split()
    first = parts[0] if parts else None
    last = parts[-1] if len(parts) > 1 else None
    return first, last, chosen.get("AGNT_TITL_TX")


# -- Stage 2b: skip-trace (person name -> phone) ------------------------
#
# VERIFIED against the real one-api/skip-trace actor (2026-08-03). "name"
# must be a single-element array containing the FULL name as one string --
# passing ["First", "Last"] as two elements runs two independent (and here,
# failed) single-token person searches instead of one combined search.
# Like the SOS actor, this is one call per lead, not a batch array.

def build_skiptrace_input(first_name, last_name, address, city, state):
    """ADJUST TO YOUR ACTOR'S SCHEMA. Verified: name is [full_name_string]."""
    full_name = f"{first_name} {last_name}".strip()
    return {
        "name": [full_name],
        "address": address or "",
        "city": city or "",
        "state": state or "TX",
    }


def parse_skiptrace_output(dataset_items):
    """
    ADJUST TO YOUR ACTOR'S SCHEMA.

    Verified real shape: dataset_items[0]["First Name"] == "Person Not Found"
    on a miss. On a hit, phones are "Phone-1".."Phone-5" (may be sparse) and
    emails "Email-1".."Email-5". Takes the first non-empty phone/email.

    IMPORTANT (found via live testing 2026-08-03): the actor does NOT hard-filter
    by the state passed in the request -- it can return its best-guess match
    for a common name in a completely different state (a McAllen, TX search
    returned a person living in Florida). Returns the matched "Address Region"
    too, so the caller can sanity-check it against the property's state before
    treating this as a real match -- see GEOGRAPHIC_MATCH_REQUIRED below.
    Returns (phone, email, matched_state) or (None, None, None) if not found.
    """
    if not dataset_items:
        return None, None, None
    item = dataset_items[0]
    if not item or item.get("First Name") == "Person Not Found":
        return None, None, None
    phone = next((item.get(f"Phone-{i}") for i in range(1, 6) if item.get(f"Phone-{i}")), None)
    email = next((item.get(f"Email-{i}") for i in range(1, 6) if item.get(f"Email-{i}")), None)
    matched_state = item.get("Address Region")
    return phone, email, matched_state


# Skip-trace matches whose "Address Region" doesn't match the property's own
# state are rejected rather than dialed -- a McAllen, TX property owner whose
# best-guess skip-trace hit lives in Florida is very likely the wrong person
# entirely (a same-name stranger), not someone who relocated. Found via live
# testing: "Alan Miller" (Trenton Street Corp's resolved officer) matched to
# an unrelated "Allan Miller" in Lithia, FL. Set to False to disable (not
# recommended -- this is a real wrong-person-call risk, not a false positive
# guard being overly cautious).
GEOGRAPHIC_MATCH_REQUIRED = True


def run_two_stage_enrichment(batch_rows, dry_run):
    """
    Runs Stage 2a (SOS resolution, entity-owned leads only) then Stage 2b
    (skip-trace, all non-institutional leads) and merges results back onto
    batch_rows. One Apify call per lead per stage -- see the "VERIFIED"
    notes above on build_sos_input/build_skiptrace_input for why this
    isn't batched into a single actor run.
    """
    if dry_run:
        merged = []
        for row in batch_rows:
            r = dict(row)
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

    merged = []
    for row in batch_rows:
        r = dict(row)
        owner = row.get("Owner Name", "")

        # Three-way split: institutional owners are excluded outright (see
        # INSTITUTIONAL_MARKERS docstring above -- SOS resolution and
        # name-based skip-trace both produce garbage for a school district
        # or county). Checked first since institutional names can also
        # contain entity-like words (e.g. "Trust" in a church name).
        if is_institutional_owner(owner):
            r["contact_first_name"] = ""
            r["contact_last_name"] = ""
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = "excluded_institutional_owner"
            merged.append(r)
            continue

        if is_entity_owned(owner):
            entity = sos_search_entity(
                owner, lambda q: run_apify_actor(APIFY_SOS_ACTOR_ID, build_sos_input(q))
            )
            first, last, title = parse_sos_output(entity)
            if first is None:
                r["contact_first_name"] = ""
                r["contact_last_name"] = ""
                r["contact_phone"] = ""
                r["contact_email"] = ""
                r["enrichment_status"] = "sos_resolution_failed"
                merged.append(r)
                continue
            search_first, search_last = first, last
        elif is_joint_owner(owner):
            # Two+ people listed together -- take only the first-listed
            # person rather than mangling both names together.
            first_person = (owner or "").split("&")[0].split(" AND ")[0].strip()
            parts = first_person.split()
            search_first = parts[0] if parts else ""
            search_last = parts[-1] if len(parts) > 1 else ""
        else:
            # individual owner -- naive first/last split of Owner Name.
            # Note: real gaps found in testing -- some unsuffixed business
            # names (e.g. "Day Surgery At Renaissance") land here too. See
            # commit history / n8n-pipeline.md for details.
            parts = (owner or "").split()
            search_first = parts[0] if parts else ""
            search_last = parts[-1] if len(parts) > 1 else ""

        r["contact_first_name"] = search_first
        r["contact_last_name"] = search_last

        if not search_first and not search_last:
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = "no_name_to_search"
            merged.append(r)
            continue

        skiptrace_items = run_apify_actor(
            APIFY_SKIPTRACE_ACTOR_ID,
            build_skiptrace_input(search_first, search_last, row.get("Property Address", ""),
                                   row.get("City", ""), "TX"),
        )
        phone, email, matched_state = parse_skiptrace_output(skiptrace_items)
        if phone and GEOGRAPHIC_MATCH_REQUIRED and matched_state and matched_state.strip().upper() != "TX":
            # Very likely a same-name stranger, not the actual owner -- see
            # GEOGRAPHIC_MATCH_REQUIRED docstring above.
            r["contact_phone"] = ""
            r["contact_email"] = ""
            r["enrichment_status"] = f"skiptrace_rejected_geo_mismatch_{matched_state}"
        elif phone:
            r["contact_phone"] = phone
            r["contact_email"] = email or ""
            r["enrichment_status"] = "matched"
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
    status, resp = http_request(
        RETELL_CREATE_CALL_URL, method="POST", headers=headers, body=payload,
        retry_on_network_error=False,  # see http_request docstring -- avoids risk of double-dialing
    )
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
