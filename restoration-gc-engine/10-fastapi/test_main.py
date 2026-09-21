"""
Tests for main.py. Run with: pytest test_main.py -v
Requires: pip install -r requirements.txt pytest respx
"""
import hashlib
import hmac
import json
import os

os.environ["FASTAPI_HMAC_SECRET"] = "test-secret"
os.environ["SUPABASE_URL"] = "https://example.supabase.co"
os.environ["SUPABASE_SERVICE_KEY"] = "test-service-key"

import httpx
import respx
from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def sign(body: bytes) -> str:
    return hmac.new(b"test-secret", body, hashlib.sha256).hexdigest()


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "ok"}


def test_storm_alert_missing_signature():
    r = client.post("/webhooks/storm-alert", content=b"{}")
    assert r.status_code == 401, r.text


def test_storm_alert_bad_signature():
    body = b'{"event_id":"x"}'
    r = client.post("/webhooks/storm-alert", content=body, headers={"X-RGC-Signature": "deadbeef"})
    assert r.status_code == 401, r.text


def test_storm_alert_valid_signature_missing_fields():
    body = json.dumps({"event_id": "HAIL-1"}).encode()  # missing event_ts, state
    r = client.post("/webhooks/storm-alert", content=body, headers={"X-RGC-Signature": sign(body)})
    assert r.status_code == 422, r.text


def test_storm_alert_valid_no_n8n_configured():
    payload = {
        "event_id": "HAIL-2026-0921-TX-001",
        "event_type": "hail",
        "event_ts": "2026-09-21T22:15:00Z",
        "max_hail_size_in": 2.25,
        "max_wind_mph": 70,
        "state": "TX",
        "properties": [{"parcel_id": "TRAVIS-01234", "address": "701 Brazos St, Austin, TX 78701", "roof_sqft": 42000}],
    }
    body = json.dumps(payload).encode()
    r = client.post("/webhooks/storm-alert", content=body, headers={"X-RGC-Signature": sign(body)})
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "validated_only", "event_id": "HAIL-2026-0921-TX-001"}


@respx.mock
def test_storm_alert_forwards_to_n8n():
    os.environ["N8N_STORM_ALERT_WEBHOOK_URL"] = "https://n8n.example.com/webhook/storm-alert"
    route = respx.post("https://n8n.example.com/webhook/storm-alert").mock(
        return_value=httpx.Response(200, json={"status": "queued", "draft": "abc-123"})
    )
    payload = {"event_id": "HAIL-2", "event_ts": "2026-09-21T22:15:00Z", "state": "TX"}
    body = json.dumps(payload).encode()
    r = client.post("/webhooks/storm-alert", content=body, headers={"X-RGC-Signature": sign(body)})
    assert route.called
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "queued", "draft": "abc-123"}
    del os.environ["N8N_STORM_ALERT_WEBHOOK_URL"]


@respx.mock
def test_storm_alert_n8n_down():
    os.environ["N8N_STORM_ALERT_WEBHOOK_URL"] = "https://n8n.example.com/webhook/storm-alert"
    respx.post("https://n8n.example.com/webhook/storm-alert").mock(side_effect=httpx.ConnectError("refused"))
    payload = {"event_id": "HAIL-3", "event_ts": "2026-09-21T22:15:00Z", "state": "TX"}
    body = json.dumps(payload).encode()
    r = client.post("/webhooks/storm-alert", content=body, headers={"X-RGC-Signature": sign(body)})
    assert r.status_code == 502, r.text
    del os.environ["N8N_STORM_ALERT_WEBHOOK_URL"]


@respx.mock
def test_approve_unknown_token():
    respx.get("https://example.supabase.co/rest/v1/approval_queue").mock(return_value=httpx.Response(200, json=[]))
    r = client.get("/approve", params={"token": "nope", "d": "approve"})
    assert r.status_code == 404, r.text


@respx.mock
def test_approve_success():
    respx.get("https://example.supabase.co/rest/v1/approval_queue").mock(
        return_value=httpx.Response(200, json=[{"id": "row-1", "decision": None}])
    )
    patch_route = respx.patch("https://example.supabase.co/rest/v1/approval_queue").mock(
        return_value=httpx.Response(204)
    )
    r = client.get("/approve", params={"token": "tok-1", "d": "approve"})
    assert r.status_code == 200, r.text
    assert "Recorded: approve" in r.text
    assert patch_route.called
    sent_body = json.loads(patch_route.calls.last.request.content)
    assert sent_body["decision"] == "approve"
    assert "decision_ts" in sent_body


@respx.mock
def test_approve_already_decided_is_idempotent():
    respx.get("https://example.supabase.co/rest/v1/approval_queue").mock(
        return_value=httpx.Response(200, json=[{"id": "row-1", "decision": "reject"}])
    )
    patch_route = respx.patch("https://example.supabase.co/rest/v1/approval_queue").mock(
        return_value=httpx.Response(204)
    )
    r = client.get("/approve", params={"token": "tok-1", "d": "approve"})
    assert r.status_code == 200, r.text
    assert "already marked 'reject'" in r.text
    assert not patch_route.called  # must not overwrite an existing decision


def test_approve_bad_decision_value():
    r = client.get("/approve", params={"token": "tok-1", "d": "bogus"})
    assert r.status_code == 422, r.text


@respx.mock
def test_retell_status_ignored_without_consent():
    body = json.dumps(
        {"call_id": "c1", "owner_id": "o1", "outcome": "connected", "consent_verified": False, "ai_disclosed": True}
    ).encode()
    r = client.post("/webhooks/retell-status", content=body, headers={"X-RGC-Signature": sign(body)})
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "ignored"


@respx.mock
def test_retell_status_logged_with_consent():
    post_route = respx.post("https://example.supabase.co/rest/v1/attribution_events").mock(
        return_value=httpx.Response(201)
    )
    body = json.dumps(
        {"call_id": "c2", "owner_id": "o2", "outcome": "connected", "consent_verified": True, "ai_disclosed": True}
    ).encode()
    r = client.post("/webhooks/retell-status", content=body, headers={"X-RGC-Signature": sign(body)})
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "logged", "call_id": "c2", "outcome": "connected"}
    assert post_route.called
    sent_body = json.loads(post_route.calls.last.request.content)
    assert sent_body["event_name"] == "voice_connect"
    assert sent_body["touch_channel"] == "voice"


def test_retell_status_bad_signature():
    body = b'{"call_id":"c3"}'
    r = client.post("/webhooks/retell-status", content=body, headers={"X-RGC-Signature": "bad"})
    assert r.status_code == 401, r.text
