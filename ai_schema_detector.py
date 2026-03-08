"""
AI Schema Detector
==================
Detects mappings from arbitrary CSV column names to the master schema fields
defined in DATA_SCHEMA.md.

Uses fuzzy string matching — no external AI API required. The "AI" label
reflects intelligent heuristics: alias dictionaries, token overlap, Levenshtein
distance, and confidence scoring.
"""

import re
import json
from typing import Optional

# ---------------------------------------------------------------------------
# Master schema fields and their known aliases
# ---------------------------------------------------------------------------
MASTER_FIELDS = [
    "owner_name",
    "owner_company",
    "owner_email",
    "owner_phone",
    "property_name",
    "address",
    "city",
    "state",
    "zip",
    "market",
    "asset_type",
    "building_sqft",
    "roof_type",
    "notes",
]

ALIASES: dict[str, list[str]] = {
    "owner_name": [
        "name", "contact", "contact_name", "person", "owner", "full_name",
        "first_last", "primary_contact", "owner name", "contact name",
        "person name", "individual",
    ],
    "owner_company": [
        "company", "organization", "org", "firm", "employer",
        "company_name", "organization_name", "business", "entity",
    ],
    "owner_email": [
        "email", "e_mail", "e-mail", "contact_email", "email_address",
        "email address", "mail",
    ],
    "owner_phone": [
        "phone", "tel", "telephone", "mobile", "cell", "phone_number",
        "phone number", "contact_phone", "contact phone", "fax",
    ],
    "property_name": [
        "property", "building", "building_name", "prop_name", "site",
        "property name", "building name", "project", "project_name",
        "asset_name", "asset name",
    ],
    "address": [
        "addr", "street", "street_address", "street address", "location",
        "mailing_address", "mailing address", "property_address",
    ],
    "city": [
        "municipality", "town", "city_name",
    ],
    "state": [
        "st", "province", "state_code", "state code",
    ],
    "zip": [
        "zip_code", "postal_code", "postal", "zipcode", "zip code",
        "postcode",
    ],
    "market": [
        "metro", "metro_area", "market_area", "region", "submarket",
        "market name", "metro area",
    ],
    "asset_type": [
        "type", "property_type", "prop_type", "class", "building_type",
        "property type", "asset class", "use_type", "use type",
    ],
    "building_sqft": [
        "sqft", "sq_ft", "square_feet", "size", "area", "gla",
        "rentable_sqft", "rentable sqft", "rsf", "building_size",
        "square footage", "square feet", "sq ft",
    ],
    "roof_type": [
        "roof", "roofing", "roof_material", "roof material",
        "roof_system", "roof system",
    ],
    "notes": [
        "note", "comment", "comments", "description", "remarks",
        "memo", "additional_notes", "additional notes",
    ],
}

# Pre-compute reverse alias lookup: normalized_alias → target_field
_ALIAS_LOOKUP: dict[str, str] = {}
for _field, _aliases in ALIASES.items():
    _ALIAS_LOOKUP[_field.lower().replace("_", " ")] = _field
    for _alias in _aliases:
        _ALIAS_LOOKUP[_alias.lower()] = _field


def _normalize_col(col: str) -> str:
    """Lowercase, strip, replace common separators with space."""
    return re.sub(r"[\s_\-\.]+", " ", col.strip().lower())


def _levenshtein(s: str, t: str) -> int:
    """Compute Levenshtein edit distance."""
    m, n = len(s), len(t)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, n + 1):
            tmp = dp[j]
            if s[i - 1] == t[j - 1]:
                dp[j] = prev
            else:
                dp[j] = 1 + min(prev, dp[j], dp[j - 1])
            prev = tmp
    return dp[n]


def _similarity(a: str, b: str) -> float:
    """Normalized similarity in [0, 1]. 1 = identical."""
    if not a and not b:
        return 1.0
    max_len = max(len(a), len(b))
    if max_len == 0:
        return 1.0
    dist = _levenshtein(a, b)
    return 1.0 - dist / max_len


def detect_field(column_name: str) -> tuple[Optional[str], str]:
    """
    Map a source column name to a master schema field.

    Returns (field_name, confidence_level) where confidence_level is one of:
      'exact'  — direct or alias match
      'fuzzy'  — best edit-distance match above threshold
      'none'   — no confident mapping found
    """
    normalized = _normalize_col(column_name)

    # 1. Exact alias lookup
    if normalized in _ALIAS_LOOKUP:
        return _ALIAS_LOOKUP[normalized], "exact"

    # 2. Fuzzy match against all aliases + field names
    best_field: Optional[str] = None
    best_score = 0.0

    candidates: dict[str, str] = {}
    for field, aliases in ALIASES.items():
        for alias in [field.replace("_", " ")] + aliases:
            candidates[alias.lower()] = field

    for candidate, field in candidates.items():
        score = _similarity(normalized, candidate)
        if score > best_score:
            best_score = score
            best_field = field

    if best_score >= 0.80:
        return best_field, "fuzzy"

    # 3. Token overlap: check if normalized contains a distinctive token
    tokens = set(normalized.split())
    for field, aliases in ALIASES.items():
        field_tokens = set(field.replace("_", " ").split())
        all_tokens = field_tokens.copy()
        for alias in aliases:
            all_tokens |= set(alias.split())
        if tokens & field_tokens and len(tokens & field_tokens) >= 1:
            # Only use if we have a high-value token match (e.g. "email", "sqft")
            distinctive = tokens & field_tokens - {"name", "type", "code"}
            if distinctive:
                return field, "fuzzy"

    return None, "none"


def _infer_from_sample_values(col: str, samples: list[str]) -> Optional[str]:
    """
    Use sample values to infer the master field when header matching fails.
    Returns a master field name or None.
    """
    non_empty = [s.strip() for s in samples if s.strip()]
    if not non_empty:
        return None

    # Email pattern
    if all(re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", v) for v in non_empty[:3]):
        return "owner_email"

    # Phone pattern
    if all(re.match(r"^[\d\s\(\)\-\+\.]{7,20}$", v) for v in non_empty[:3]):
        return "owner_phone"

    # ZIP code pattern
    if all(re.match(r"^\d{5}(-\d{4})?$", v) for v in non_empty[:3]):
        return "zip"

    # 2-letter state codes
    if all(re.match(r"^[A-Za-z]{2}$", v) for v in non_empty[:3]):
        return "state"

    # Full state names → state field
    state_names = {
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado",
        "connecticut", "delaware", "florida", "georgia", "hawaii", "idaho",
        "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana",
        "maine", "maryland", "massachusetts", "michigan", "minnesota",
        "mississippi", "missouri", "montana", "nebraska", "nevada",
        "new hampshire", "new jersey", "new mexico", "new york",
        "north carolina", "north dakota", "ohio", "oklahoma", "oregon",
        "pennsylvania", "rhode island", "south carolina", "south dakota",
        "tennessee", "texas", "utah", "vermont", "virginia", "washington",
        "west virginia", "wisconsin", "wyoming",
    }
    if all(v.lower() in state_names for v in non_empty[:3]):
        return "state"

    # Numeric large integers → building_sqft candidate
    if all(re.match(r"^[\d,]+$", v) for v in non_empty[:3]):
        vals = [int(v.replace(",", "")) for v in non_empty[:3] if v.replace(",", "").isdigit()]
        if vals and all(1000 <= v <= 5_000_000 for v in vals):
            return "building_sqft"

    # Asset type values
    valid_asset = {
        "multifamily", "retail strip", "office", "flex industrial",
        "industrial", "hospitality", "mixed use", "land", "other",
        "retail", "flex", "multi-family",
    }
    if any(v.lower() in valid_asset for v in non_empty[:3]):
        return "asset_type"

    # Roof type values
    valid_roof = {
        "tpo membrane", "tpo", "built-up", "metal", "shingle",
        "epdm", "modified bitumen", "other",
    }
    if any(v.lower() in valid_roof for v in non_empty[:3]):
        return "roof_type"

    return None


def detect_schema(
    columns: list[str],
    sample_rows: Optional[list[dict]] = None,
) -> dict:
    """
    Detect mappings for a list of source column names.

    Args:
      columns:     List of header strings from the source CSV.
      sample_rows: Optional list of row dicts (up to 5) for value-based inference.

    Returns a dict with:
      detected_mappings: {source_col: master_field}
      unmapped_columns:  [source_col, ...]
      confidence:        overall confidence label
    """
    detected: dict[str, str] = {}
    unmapped: list[str] = []
    confidence_levels: list[str] = []

    for col in columns:
        field, level = detect_field(col)

        # If header matching failed, try sample-value inference
        if (field is None or level == "none") and sample_rows:
            samples = [str(row.get(col, "")) for row in sample_rows[:5]]
            field = _infer_from_sample_values(col, samples)
            if field:
                level = "fuzzy"

        if field and level != "none":
            # Avoid mapping two columns to the same target (first wins)
            if field not in detected.values():
                detected[col] = field
                confidence_levels.append(level)
            else:
                unmapped.append(col)
        else:
            unmapped.append(col)

    # Overall confidence
    if not detected:
        overall = "none"
    elif all(c == "exact" for c in confidence_levels):
        overall = "high"
    elif any(c == "exact" for c in confidence_levels):
        overall = "medium"
    else:
        overall = "low"

    return {
        "detected_mappings": detected,
        "unmapped_columns": unmapped,
        "confidence": overall,
    }


def build_schema_map(file_schemas: dict[str, dict]) -> str:
    """Serialize the schema map to a JSON string."""
    return json.dumps(file_schemas, indent=2)
