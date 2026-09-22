#!/usr/bin/env python3
"""
Creates the restorationgc property group and all custom properties from
custom_properties.json via the HubSpot CRM v3 Properties API.

Usage:
    export HUBSPOT_PRIVATE_APP_TOKEN=pat-na1-xxxxxxxx
    python3 create_properties.py [--object-type contacts] [--dry-run]

Requires only the Python standard library (no pip install needed) so it can
run anywhere: your laptop, an n8n Execute Command node, or a CI job.

Idempotent: re-running is safe. A property or group that already exists
(HubSpot returns 409 Conflict) is reported as "already exists" and skipped,
not treated as an error.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API_BASE = "https://api.hubapi.com"
GROUP_NAME = "restorationgc"
GROUP_LABEL = "Restoration GC"
PROPERTIES_FILE = Path(__file__).parent / "custom_properties.json"


def api_request(method: str, path: str, token: str, body: dict | None = None):
    url = f"{API_BASE}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def ensure_property_group(object_type: str, token: str, dry_run: bool) -> None:
    if dry_run:
        print(f"[dry-run] would ensure property group '{GROUP_NAME}' exists on {object_type}")
        return
    status, resp = api_request(
        "POST",
        f"/crm/v3/properties/{object_type}/groups",
        token,
        {"name": GROUP_NAME, "label": GROUP_LABEL},
    )
    if status == 201:
        print(f"created property group '{GROUP_NAME}' on {object_type}")
    elif status == 409:
        print(f"property group '{GROUP_NAME}' already exists on {object_type} — skipping")
    else:
        print(f"ERROR creating property group: HTTP {status} — {resp}", file=sys.stderr)
        sys.exit(1)


def create_property(object_type: str, prop: dict, token: str, dry_run: bool) -> None:
    if dry_run:
        print(f"[dry-run] would create property '{prop['name']}' on {object_type}")
        return
    status, resp = api_request("POST", f"/crm/v3/properties/{object_type}", token, prop)
    if status == 201:
        print(f"created property '{prop['name']}'")
    elif status == 409:
        print(f"property '{prop['name']}' already exists — skipping")
    else:
        print(f"ERROR creating property '{prop['name']}': HTTP {status} — {resp}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--object-type",
        default="contacts",
        help="HubSpot object type to create the properties on (default: contacts). "
        "Run again with --object-type companies if you also want rgc_portfolio_id "
        "and friends available on Company records.",
    )
    parser.add_argument("--dry-run", action="store_true", help="print what would happen without calling the API")
    args = parser.parse_args()

    token = os.environ.get("HUBSPOT_PRIVATE_APP_TOKEN")
    if not token and not args.dry_run:
        print("ERROR: set HUBSPOT_PRIVATE_APP_TOKEN in the environment (or pass --dry-run)", file=sys.stderr)
        sys.exit(1)

    properties = json.loads(PROPERTIES_FILE.read_text())

    ensure_property_group(args.object_type, token, args.dry_run)
    for prop in properties:
        create_property(args.object_type, prop, token, args.dry_run)


if __name__ == "__main__":
    main()
