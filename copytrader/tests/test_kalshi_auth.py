import base64, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from copytrader.kalshi import KalshiClient


def test_request_signature_verifies_with_public_key():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        f.write(pem); path = f.name
    k = KalshiClient("https://demo-api.kalshi.co/trade-api/v2", "key-id-123", path)
    assert k.authed
    h = k._headers("GET", "/portfolio/balance")
    assert h["KALSHI-ACCESS-KEY"] == "key-id-123"
    msg = (h["KALSHI-ACCESS-TIMESTAMP"] + "GET" + "/trade-api/v2/portfolio/balance").encode()
    key.public_key().verify(base64.b64decode(h["KALSHI-ACCESS-SIGNATURE"]), msg,
                            padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=padding.PSS.DIGEST_LENGTH),
                            hashes.SHA256())                                  # raises if the signature is wrong
    os.remove(path)


def test_unauthenticated_client_reports_not_authed():
    assert not KalshiClient("https://demo-api.kalshi.co/trade-api/v2").authed
