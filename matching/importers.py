"""CSV/JSON parsing helpers for self-exported contact and target lists.

Every importer here reads data a partner already legitimately holds
(their own LinkedIn/Facebook/phone/email export) or a target list the
business already sources from public records. Column names vary a lot
between export tools, so each parser matches loosely on header names
rather than requiring an exact format.
"""
import csv
import io
import json
import re


def _normalize(header):
    return header.strip().lower().replace("_", " ")


def _find_column(headers, candidates):
    normalized = {_normalize(h): h for h in headers}
    for candidate in candidates:
        if candidate in normalized:
            return normalized[candidate]
    for norm_header, original in normalized.items():
        for candidate in candidates:
            if candidate in norm_header:
                return original
    return None


def _read_rows(file_obj):
    text = file_obj.read()
    if isinstance(text, bytes):
        text = text.decode("utf-8-sig", errors="replace")
    return list(csv.reader(io.StringIO(text)))


def parse_linkedin_export(file_obj):
    """Parse a LinkedIn 'Connections.csv' data export.

    LinkedIn prefixes the real header row with a few "Notes:" lines, so
    we scan for the first row that looks like the actual header.
    """
    rows = _read_rows(file_obj)
    header_idx = None
    for i, row in enumerate(rows):
        joined = ",".join(row).lower()
        if "first name" in joined and "last name" in joined:
            header_idx = i
            break
    if header_idx is None:
        raise ValueError("Could not find a header row containing 'First Name' / 'Last Name'")

    headers = rows[header_idx]
    col_first = _find_column(headers, ["first name"])
    col_last = _find_column(headers, ["last name"])
    col_email = _find_column(headers, ["email address", "email"])
    col_company = _find_column(headers, ["company"])

    results = []
    for row in rows[header_idx + 1:]:
        if not any(row):
            continue
        record = dict(zip(headers, row))
        first = record.get(col_first, "").strip() if col_first else ""
        last = record.get(col_last, "").strip() if col_last else ""
        full_name = f"{first} {last}".strip()
        if not full_name:
            continue
        results.append({
            "full_name": full_name,
            "email": record.get(col_email, "").strip() if col_email else "",
            "company": record.get(col_company, "").strip() if col_company else "",
            "phone": "",
            "raw_data": record,
        })
    return results


def _fix_facebook_mojibake(value):
    """Facebook's JSON export encodes non-ASCII text incorrectly: UTF-8
    bytes get escaped as if they were Latin-1. Re-decoding fixes names
    with accents/emoji; left as-is if that round-trip isn't possible
    (already-correct exports from some newer tools)."""
    if not value:
        return value
    try:
        return value.encode("latin1").decode("utf8")
    except (UnicodeDecodeError, UnicodeEncodeError):
        return value


def parse_facebook_export(file_obj):
    """Parse a Facebook 'Download Your Information' friends export.

    Facebook's own export (Settings -> Your Facebook Information ->
    Download Your Information -> Friends and Followers -> JSON) produces
    a friends_and_followers/friends.json file shaped like
    {"friends_v2": [{"name": "...", "timestamp": ...}, ...]}. Facebook
    does not include friends' emails/phones in this export (only your
    own account's contact info is yours to export) -- name-only records
    are expected and are still useful for name-based matching.
    """
    raw = file_obj.read()
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        raise ValueError("Could not parse this as a Facebook friends export (expected JSON).")

    friends = data.get("friends_v2")
    if friends is None and isinstance(data.get("friends"), dict):
        friends = data["friends"].get("friends_v2")
    if friends is None:
        raise ValueError(
            "Could not find a 'friends_v2' list in this file. Make sure you selected "
            "'Friends and Followers' in JSON format from Facebook's Download Your Information tool."
        )

    results = []
    for entry in friends:
        if not isinstance(entry, dict):
            continue
        full_name = _fix_facebook_mojibake(entry.get("name", "")).strip()
        if not full_name:
            continue
        results.append({
            "full_name": full_name,
            "email": "",
            "phone": "",
            "company": "",
            "raw_data": entry,
        })
    return results


def parse_generic_contacts(file_obj):
    """Parse a generic phone/email address-book CSV export (Google, Apple, Outlook, ...)."""
    rows = _read_rows(file_obj)
    if not rows:
        return []
    headers = rows[0]

    col_full_name = _find_column(headers, ["full name", "name"])
    col_first = _find_column(headers, ["first name", "given name"])
    col_last = _find_column(headers, ["last name", "family name", "surname"])
    col_email = _find_column(headers, ["e-mail 1 - value", "email 1 - value", "e-mail", "email"])
    col_phone = _find_column(headers, ["phone 1 - value", "phone number", "phone"])
    col_company = _find_column(headers, ["organization 1 - name", "organization", "company"])

    results = []
    for row in rows[1:]:
        if not any(row):
            continue
        record = dict(zip(headers, row))
        full_name = record.get(col_full_name, "").strip() if col_full_name else ""
        if not full_name:
            first = record.get(col_first, "").strip() if col_first else ""
            last = record.get(col_last, "").strip() if col_last else ""
            full_name = f"{first} {last}".strip()
        if not full_name:
            continue
        results.append({
            "full_name": full_name,
            "email": record.get(col_email, "").strip() if col_email else "",
            "phone": record.get(col_phone, "").strip() if col_phone else "",
            "company": record.get(col_company, "").strip() if col_company else "",
            "raw_data": record,
        })
    return results


_COMBINED_ADDRESS_RE = re.compile(
    r"^(?P<street>.+?),\s*(?P<city>[^,]+?),\s*(?P<state>[A-Za-z]{2})\s+(?P<zip>\d{5}(?:-\d{4})?)$"
)


def _split_combined_address(value):
    """Splits a single "123 Main St, Austin, TX 78701"-style field into
    parts. Returns None if it doesn't look like that shape, so the
    caller can fall back to storing the whole string as-is."""
    if not value:
        return None
    match = _COMBINED_ADDRESS_RE.match(value.strip())
    return match.groupdict() if match else None


def parse_targets(file_obj):
    """Parse a commercial-building-owner / hail-damage target list CSV.

    Column names vary a lot by source. Supports both a clean, dedicated
    Owner Name / Address / City / State / Zip layout and a CRM-style
    export (First Name / Last Name / Company Name / a single combined
    address field like HubSpot's "Deal" column).
    """
    rows = _read_rows(file_obj)
    if not rows:
        return []
    headers = rows[0]

    col_owner = _find_column(headers, ["owner name", "owner"])
    col_first = _find_column(headers, ["first name"])
    col_last = _find_column(headers, ["last name"])
    col_entity = _find_column(headers, ["entity name", "entity", "llc", "business name", "company name", "company"])
    col_ticker = _find_column(headers, ["ticker", "stock ticker", "symbol"])
    col_address = _find_column(headers, ["address", "street"])
    col_combined_address = _find_column(headers, ["deal", "full address"])
    col_city = _find_column(headers, ["city"])
    col_state = _find_column(headers, ["state"])
    col_zip = _find_column(headers, ["zip", "zip code", "postal code"])
    col_phone = _find_column(headers, ["phone", "mobile phone"])
    col_email = _find_column(headers, ["email"])
    col_damage_type = _find_column(headers, ["damage type", "damage"])
    col_damage_date = _find_column(headers, ["damage date", "date"])
    col_notes = _find_column(headers, ["notes", "source"])
    col_contact_title = _find_column(headers, ["contact"])

    results = []
    for row in rows[1:]:
        if not any(row):
            continue
        record = dict(zip(headers, row))

        owner_name = record.get(col_owner, "").strip() if col_owner else ""
        if not owner_name and (col_first or col_last):
            first = record.get(col_first, "").strip() if col_first else ""
            last = record.get(col_last, "").strip() if col_last else ""
            owner_name = f"{first} {last}".strip()
        if not owner_name:
            continue

        address = record.get(col_address, "").strip() if col_address else ""
        city = record.get(col_city, "").strip() if col_city else ""
        state = record.get(col_state, "").strip() if col_state else ""
        zip_code = record.get(col_zip, "").strip() if col_zip else ""
        if not address and col_combined_address:
            combined = record.get(col_combined_address, "").strip()
            parsed = _split_combined_address(combined)
            if parsed:
                address = parsed["street"]
                city = city or parsed["city"]
                state = state or parsed["state"]
                zip_code = zip_code or parsed["zip"]
            else:
                address = combined

        source_notes = record.get(col_notes, "").strip() if col_notes else ""
        if not source_notes and col_contact_title:
            source_notes = record.get(col_contact_title, "").strip()

        results.append({
            "owner_name": owner_name,
            "entity_name": record.get(col_entity, "").strip() if col_entity else "",
            "ticker": record.get(col_ticker, "").strip() if col_ticker else "",
            "address": address,
            "city": city,
            "state": state,
            "zip_code": zip_code,
            "phone": record.get(col_phone, "").strip() if col_phone else "",
            "email": record.get(col_email, "").strip() if col_email else "",
            "damage_type": (record.get(col_damage_type, "").strip() if col_damage_type else "") or "hail",
            "damage_date": record.get(col_damage_date, "").strip() if col_damage_date else "",
            "source_notes": source_notes,
            "raw_data": record,
        })
    return results
