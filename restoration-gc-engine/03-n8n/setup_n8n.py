#!/usr/bin/env python3
"""
Creates the n8n credentials this build's workflows reference, and imports
W1 and W4 (the two workflows shipped as full, importable JSON — see the
other workflows' .md specs, which still need to be built by hand in the
editor). Both import INACTIVE regardless of any gate below; activating
W4 in the n8n editor is a deliberate manual step, never done by this
script — see the "IMPORTANT: W4" note below.

Usage:
    export N8N_BASE_URL=https://your-instance.app.n8n.cloud   # no trailing slash
    export N8N_API_KEY=n8n_api_...                             # Settings > n8n API > Create an API key

    # Secret-based credentials (skip any you don't want to create yet by
    # leaving its env var unset - the script reports "skipped, no value").
    export SUPABASE_DB_HOST=db.bccpaguzuowwgokxgsjh.supabase.co   # or the pooler host, see note below
    export SUPABASE_DB_PORT=5432
    export SUPABASE_DB_NAME=postgres
    export SUPABASE_DB_USER=postgres
    export SUPABASE_DB_PASSWORD=...                                # from the Supabase dashboard, not this repo
    export OPENAI_API_KEY=sk-...
    export RETELL_API_KEY=...
    export FASTAPI_HMAC_SECRET=...

    python3 setup_n8n.py            # create credentials + import W1 and W4
    python3 setup_n8n.py --dry-run  # preview without calling the API

Requires only the Python standard library.

IMPORTANT: W4 dispatches real emails and (via Retell) real AI-voice phone
calls once active. This script imports it INACTIVE, same as W1 — n8n's
create-workflow API defaults to inactive and this script never overrides
that. Activating W4 is a manual step in the n8n editor and should only
happen after BOTH: (1) MJ's own sign-off on the Retell consent flow
(nothing in code can substitute for a human verifying that flow works
end to end), and (2) a clean compliance red-team run
(08-testing/compliance_redteam.md / run_redteam.py). Pass --skip-w4 to
import only W1 if you are not ready for W4 to exist in your instance at
all yet.

WHAT THIS SCRIPT CANNOT DO, AND WHY (not a bug - an n8n/OAuth constraint):
  RGC_GMAIL_OAUTH and RGC_LINKEDIN_OAUTH are OAuth2 credentials. n8n's API can
  create the credential shell, but the credential is not actually AUTHORIZED
  until a human completes the OAuth consent redirect in the n8n editor UI
  (Credentials -> New -> pick the OAuth2 type -> Connect my account). There is
  no way to script that hop for a real user's Google/LinkedIn login. This
  script prints exactly what to click instead of pretending to automate it.

  SUPABASE_DB_HOST: Supabase project creation does not return the database
  password anywhere retrievable by tooling. Get the exact connection string
  from: Supabase Dashboard -> restoration-gc-engine project -> Project
  Settings -> Database -> Connection string. Use the "Session pooler" or
  "Transaction pooler" host if your n8n instance is serverless/short-lived;
  the direct db.<ref>.supabase.co host also works for a long-running n8n.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

W1_FILE = Path(__file__).parent / "W1_storm_detect_to_queue.json"
W4_FILE = Path(__file__).parent / "W4_consent_gated_dispatch.json"

# name -> (n8n credential type, {field: env_var}) for the credentials this
# script CAN create end-to-end via API (secret/API-key based, not OAuth).
# Field names match n8n's built-in credential schemas as of n8n 1.x; verify
# against your instance's version if a create call comes back 400.
SCRIPTABLE_CREDENTIALS = {
    "RGC_SUPABASE_SERVICE": (
        "postgres",
        {
            "host": "SUPABASE_DB_HOST",
            "port": "SUPABASE_DB_PORT",
            "database": "SUPABASE_DB_NAME",
            "user": "SUPABASE_DB_USER",
            "password": "SUPABASE_DB_PASSWORD",
        },
    ),
    "RGC_OPENAI": ("openAiApi", {"apiKey": "OPENAI_API_KEY"}),
    # Retell has no native n8n node/credential type; W4 calls it via an HTTP
    # Request node, so we store the key as a generic header-auth credential.
    # Retell's API expects "Authorization: Bearer <key>", not the bare key.
    "RGC_RETELL_API": ("httpHeaderAuth", {"name": "__literal__Authorization", "value": "__bearer__RETELL_API_KEY"}),
    # Likewise the FastAPI HMAC secret isn't a credential type of its own -
    # store it the same way for any node that needs to read it.
    "RGC_FASTAPI_HMAC": ("httpHeaderAuth", {"name": "__literal__X-RGC-Signature-Secret", "value": "FASTAPI_HMAC_SECRET"}),
}

# OAuth2 credentials that MUST be finished by a human in the n8n editor.
OAUTH_CREDENTIALS = {
    "RGC_GMAIL_OAUTH": "Gmail OAuth2 API",
    "RGC_LINKEDIN_OAUTH": "LinkedIn OAuth2 API (or your Community Management API app's OAuth2 credential once approved)",
}


def api_request(method: str, path: str, base_url: str, api_key: str, body: dict | None = None):
    url = f"{base_url}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-N8N-API-KEY", api_key)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def create_credential(name: str, cred_type: str, field_env_map: dict, base_url: str, api_key: str, dry_run: bool) -> None:
    data = {}
    missing = []
    for field, env_ref in field_env_map.items():
        if env_ref.startswith("__literal__"):
            data[field] = env_ref[len("__literal__"):]
            continue
        if env_ref.startswith("__bearer__"):
            real_ref = env_ref[len("__bearer__"):]
            value = os.environ.get(real_ref)
            if value is None:
                missing.append(real_ref)
            else:
                data[field] = f"Bearer {value}"
            continue
        value = os.environ.get(env_ref)
        if value is None:
            missing.append(env_ref)
        else:
            data[field] = value
    if missing:
        print(f"skipped '{name}' — no value set for: {', '.join(missing)}")
        return
    if dry_run:
        safe_data = {k: ("***" if k not in ("host", "port", "database", "user", "name") else v) for k, v in data.items()}
        print(f"[dry-run] would create credential '{name}' (type={cred_type}) with fields: {safe_data}")
        return
    status, resp = api_request("POST", "/api/v1/credentials", base_url, api_key, {"name": name, "type": cred_type, "data": data})
    if status == 200:
        print(f"created credential '{name}' (id={resp.get('id')})")
    else:
        print(f"ERROR creating credential '{name}': HTTP {status} — {resp}", file=sys.stderr)


def import_workflow(file_path: Path, base_url: str, api_key: str, dry_run: bool, activation_note: str) -> None:
    workflow = json.loads(file_path.read_text())
    # The public API accepts name/nodes/connections/settings on create; strip
    # anything else the raw export might carry (e.g. an id from a prior export).
    body = {
        "name": workflow["name"],
        "nodes": workflow["nodes"],
        "connections": workflow["connections"],
        "settings": workflow.get("settings", {}),
    }
    if dry_run:
        print(f"[dry-run] would import workflow '{body['name']}' ({len(body['nodes'])} nodes)")
        return
    status, resp = api_request("POST", "/api/v1/workflows", base_url, api_key, body)
    if status in (200, 201):
        print(f"imported workflow '{body['name']}' (id={resp.get('id')}) — left INACTIVE. {activation_note}")
    else:
        print(f"ERROR importing {file_path.name}: HTTP {status} — {resp}", file=sys.stderr)


def print_oauth_instructions() -> None:
    print("\nThe following credentials need a human to finish an OAuth consent flow in the n8n editor:")
    for name, hint in OAUTH_CREDENTIALS.items():
        print(f"  - {name}: Credentials -> New Credential -> \"{hint}\" -> fill in Client ID/Secret -> Connect my account -> complete the browser consent screen.")
    print("There is no API-only path around this step for either provider.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print what would happen without calling the n8n API")
    parser.add_argument("--skip-import", action="store_true", help="only create credentials, don't import W1 or W4")
    parser.add_argument("--skip-w4", action="store_true", help="import W1 only; don't create W4 in this n8n instance at all yet")
    args = parser.parse_args()

    base_url = os.environ.get("N8N_BASE_URL", "").rstrip("/")
    api_key = os.environ.get("N8N_API_KEY")
    if not args.dry_run and (not base_url or not api_key):
        print("ERROR: set N8N_BASE_URL and N8N_API_KEY in the environment (or pass --dry-run)", file=sys.stderr)
        sys.exit(1)

    for name, (cred_type, field_env_map) in SCRIPTABLE_CREDENTIALS.items():
        create_credential(name, cred_type, field_env_map, base_url, api_key, args.dry_run)

    if not args.skip_import:
        import_workflow(W1_FILE, base_url, api_key, args.dry_run, "Activate manually once credentials are wired to its nodes.")
        if not args.skip_w4:
            import_workflow(
                W4_FILE, base_url, api_key, args.dry_run,
                "DO NOT ACTIVATE until MJ's Retell consent-flow sign-off AND a clean red-team run are both confirmed — see this script's docstring.",
            )

    print_oauth_instructions()


if __name__ == "__main__":
    main()
