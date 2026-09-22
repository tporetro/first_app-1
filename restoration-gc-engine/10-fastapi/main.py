"""
Restoration GC storm-alert / approval / voice-status webhook backend.

Implements the 3 endpoints specified in 03-n8n/fastapi_webhook_contract.md:
  POST /webhooks/storm-alert   - HMAC-verified; forwards validated payload to n8n's W1 webhook
  GET  /approve                 - one-tap approve/edit/reject from the W6 email digest
  POST /webhooks/retell-status  - HMAC-verified; logs a voice-call outcome to Supabase
  GET  /webhooks/linkedin       - LinkedIn Community Management API validation handshake

Talks to Supabase via its REST API (PostgREST) with the service_role key rather
than a direct Postgres connection, so this service only needs one dependency
(httpx) beyond FastAPI itself.

Environment variables (all required except where noted):
  FASTAPI_HMAC_SECRET       shared secret for verifying X-RGC-Signature headers
  SUPABASE_URL              e.g. https://bccpaguzuowwgokxgsjh.supabase.co
  SUPABASE_SERVICE_KEY      service_role key (bypasses RLS - never expose client-side)
  N8N_STORM_ALERT_WEBHOOK_URL   full URL to n8n's W1 webhook (optional; if unset,
                                 /webhooks/storm-alert validates and returns 202
                                 without forwarding, useful for testing this service
                                 standalone before n8n is wired up)
  LINKEDIN_CLIENT_SECRET     the app's Client Secret from the LinkedIn Developer
                             Portal; used only to compute the webhook validation
                             challengeResponse, never sent anywhere

Run locally:
    pip install -r requirements.txt
    export FASTAPI_HMAC_SECRET=... SUPABASE_URL=... SUPABASE_SERVICE_KEY=...
    uvicorn main:app --reload
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import os
from datetime import datetime, timezone
from typing import Literal

import httpx
from fastapi import FastAPI, Header, HTTPException, Request, Response
from pydantic import BaseModel, ValidationError

logger = logging.getLogger("rgc_webhooks")

app = FastAPI(title="Restoration GC Webhooks", version="1.0.0")


# --------------------------------------------------------------------------
# Config (read lazily, not at import time, so the module can be imported by
# tests without every env var set)
# --------------------------------------------------------------------------
def _env(name: str, required: bool = True) -> str | None:
    value = os.environ.get(name)
    if required and not value:
        raise RuntimeError(f"missing required environment variable: {name}")
    return value


def supabase_headers() -> dict:
    key = _env("SUPABASE_SERVICE_KEY")
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }


# --------------------------------------------------------------------------
# HMAC verification — shared by both webhook endpoints
# --------------------------------------------------------------------------
def verify_signature(raw_body: bytes, signature_header: str | None) -> None:
    secret = _env("FASTAPI_HMAC_SECRET")
    if not signature_header:
        raise HTTPException(status_code=401, detail="missing X-RGC-Signature header")
    expected = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature_header.strip().lower()):
        raise HTTPException(status_code=401, detail="invalid signature")


# --------------------------------------------------------------------------
# POST /webhooks/storm-alert
# --------------------------------------------------------------------------
class PropertyIn(BaseModel):
    parcel_id: str | None = None
    address: str
    geom_geojson: dict | None = None
    roof_sqft: int | None = None


class StormAlertPayload(BaseModel):
    event_id: str
    event_type: str = "hail"
    event_ts: datetime
    max_hail_size_in: float | None = None
    max_wind_mph: int | None = None
    state: str
    swath_geojson: dict | None = None
    properties: list[PropertyIn] = []


@app.post("/webhooks/storm-alert")
async def storm_alert(request: Request, x_rgc_signature: str | None = Header(default=None)):
    raw_body = await request.body()
    verify_signature(raw_body, x_rgc_signature)

    try:
        payload = StormAlertPayload.model_validate_json(raw_body)
    except ValidationError as e:
        raise HTTPException(status_code=422, detail=e.errors()) from e

    webhook_url = _env("N8N_STORM_ALERT_WEBHOOK_URL", required=False)
    if not webhook_url:
        logger.warning("N8N_STORM_ALERT_WEBHOOK_URL not set — payload validated but not forwarded")
        return {"status": "validated_only", "event_id": payload.event_id}

    async with httpx.AsyncClient(timeout=15.0) as client:
        try:
            resp = await client.post(webhook_url, content=raw_body, headers={"Content-Type": "application/json"})
        except httpx.HTTPError as e:
            logger.error("failed to reach n8n W1 webhook: %s", e)
            raise HTTPException(status_code=502, detail="downstream workflow unreachable") from e

    if resp.status_code >= 400:
        logger.error("n8n W1 webhook returned %s: %s", resp.status_code, resp.text)
        raise HTTPException(status_code=502, detail="downstream workflow rejected the payload")

    return resp.json()


# --------------------------------------------------------------------------
# GET /approve
# --------------------------------------------------------------------------
Decision = Literal["approve", "edit", "reject"]

APPROVE_CONFIRMATION_HTML = """<!doctype html><html><head><meta charset="utf-8">
<title>Restoration GC — Approval Recorded</title>
<style>body{{font-family:system-ui,Arial,sans-serif;max-width:480px;margin:80px auto;text-align:center;color:#111}}
h1{{font-size:1.3rem}}</style></head>
<body><h1>{message}</h1><p>You can close this tab.</p></body></html>"""


@app.get("/approve", response_class=Response)
async def approve(token: str, d: Decision):
    # This is opened directly from an email link by a human, not called programmatically -
    # a raw 500 on a Supabase outage/misconfiguration would show them an unhelpful blank
    # error page, so network-level failures (not just error status codes) get the same
    # clean 502 treatment as an HTTP-level error.
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            lookup = await client.get(
                f"{_env('SUPABASE_URL')}/rest/v1/approval_queue",
                params={"one_tap_token": f"eq.{token}", "select": "id,decision"},
                headers=supabase_headers(),
            )
            if lookup.status_code >= 400:
                raise HTTPException(status_code=502, detail="could not reach Supabase")
            rows = lookup.json()
            if not rows:
                raise HTTPException(status_code=404, detail="unknown or expired approval token")

            row = rows[0]
            if row["decision"] is not None:
                html = APPROVE_CONFIRMATION_HTML.format(
                    message=f"This item was already marked '{row['decision']}' — no change made."
                )
                return Response(content=html, media_type="text/html")

            patch = await client.patch(
                f"{_env('SUPABASE_URL')}/rest/v1/approval_queue",
                params={"id": f"eq.{row['id']}"},
                headers=supabase_headers(),
                json={"decision": d, "decision_ts": datetime.now(timezone.utc).isoformat()},
            )
            if patch.status_code >= 400:
                logger.error("failed to record approval decision: %s", patch.text)
                raise HTTPException(status_code=502, detail="could not record decision")
    except httpx.HTTPError as e:
        logger.error("could not reach Supabase for /approve: %s", e)
        raise HTTPException(status_code=502, detail="could not reach Supabase") from e

    html = APPROVE_CONFIRMATION_HTML.format(message=f"Recorded: {d}")
    return Response(content=html, media_type="text/html")


# --------------------------------------------------------------------------
# POST /webhooks/retell-status
# --------------------------------------------------------------------------
class RetellStatusPayload(BaseModel):
    call_id: str
    owner_id: str | None = None
    outcome: str
    consent_verified: bool
    ai_disclosed: bool


@app.post("/webhooks/retell-status")
async def retell_status(request: Request, x_rgc_signature: str | None = Header(default=None)):
    raw_body = await request.body()
    verify_signature(raw_body, x_rgc_signature)

    try:
        payload = RetellStatusPayload.model_validate_json(raw_body)
    except ValidationError as e:
        raise HTTPException(status_code=422, detail=e.errors()) from e

    # Never log a call as a legitimate voice touch if consent/disclosure weren't
    # confirmed - this mirrors the chk_consent_disclosure DB constraint and the
    # W4 IF-node gate, so a bad Retell payload can't backdoor an attribution event.
    if not (payload.consent_verified and payload.ai_disclosed):
        logger.warning("retell-status for call %s missing consent/disclosure — not logged", payload.call_id)
        return {"status": "ignored", "reason": "consent_or_disclosure_not_confirmed"}

    event = {
        "owner_id": payload.owner_id,
        "event_name": "voice_connect",
        "touch_channel": "voice",
        "occurred_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"{_env('SUPABASE_URL')}/rest/v1/attribution_events",
                headers={**supabase_headers(), "Prefer": "return=minimal"},
                json=event,
            )
    except httpx.HTTPError as e:
        logger.error("could not reach Supabase for call %s: %s", payload.call_id, e)
        raise HTTPException(status_code=502, detail="could not log attribution event") from e
    if resp.status_code >= 400:
        logger.error("failed to log attribution_event for call %s: %s", payload.call_id, resp.text)
        raise HTTPException(status_code=502, detail="could not log attribution event")

    return {"status": "logged", "call_id": payload.call_id, "outcome": payload.outcome}


# --------------------------------------------------------------------------
# GET /webhooks/linkedin — Community Management API validation handshake
# --------------------------------------------------------------------------
# LinkedIn calls this with ?challengeCode=... both when the webhook URL is
# first registered and again every 2 hours to re-validate it; 3 consecutive
# failures (wrong response shape, non-200, or >3s) gets the webhook blocked.
# See 06-linkedin/community_api_application.md's application checklist.
@app.get("/webhooks/linkedin")
async def linkedin_webhook_validate(challengeCode: str):
    secret = _env("LINKEDIN_CLIENT_SECRET")
    challenge_response = hmac.new(secret.encode("utf-8"), challengeCode.encode("utf-8"), hashlib.sha256).hexdigest()
    return {"challengeCode": challengeCode, "challengeResponse": challenge_response}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
