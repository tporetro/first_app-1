import base64

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, padding, rsa

from copytrader.kalshi import Signer


def _pem(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


@pytest.mark.parametrize("kind", ["ed25519", "rsa"])
def test_signature_over_ts_method_path_without_query(kind):
    key = ed25519.Ed25519PrivateKey.generate() if kind == "ed25519" else \
        rsa.generate_private_key(public_exponent=65537, key_size=2048)
    s = Signer("kid", _pem(key))
    assert s.kind == kind
    h = s.headers("post", "https://api.elections.kalshi.com/trade-api/v2/portfolio/events/orders?x=1")
    msg = (h["KALSHI-ACCESS-TIMESTAMP"] + "POST" + "/trade-api/v2/portfolio/events/orders").encode()
    sig = base64.b64decode(h["KALSHI-ACCESS-SIGNATURE"])
    if kind == "ed25519":
        key.public_key().verify(sig, msg)
    else:
        key.public_key().verify(sig, msg, padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                                                      salt_length=padding.PSS.DIGEST_LENGTH),
                                hashes.SHA256())
    assert h["KALSHI-ACCESS-KEY"] == "kid"


def test_bad_private_key_does_not_crash(monkeypatch, caplog):
    from copytrader.config import KalshiConfig
    from copytrader.kalshi import KalshiClient

    monkeypatch.setenv("KALSHI_API_KEY_ID", "abc")
    monkeypatch.setenv("KALSHI_PRIVATE_KEY", "-----BEGIN PRIVATE KEY-----\ngarbage\n-----END PRIVATE KEY-----")
    client = KalshiClient(KalshiConfig())
    assert client.authenticated is False
    assert "could not be loaded" in caplog.text
