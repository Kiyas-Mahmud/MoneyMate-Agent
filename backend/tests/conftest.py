import base64
import os
import tempfile

import pytest

_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
os.environ["DATABASE_URL"] = f"sqlite:///{_db.name}"
os.environ["GEMINI_API_KEY"] = ""  # tests use the deterministic agent path
os.environ["FX_LIVE"] = "false"   # no network in tests; live FX is tested with a mocked HTTP call
os.environ["MONITOR_ENABLED"] = "false"  # the monitor is run explicitly in tests
os.environ["ANCHOR_ENABLED"] = "false"   # no blockchain in tests; anchoring is tested with a fake chain
os.environ["ANCHOR_PRIVATE_KEY"] = ""
os.environ["VERIFICATION_MODE"] = "device"
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-not-for-production")

from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.core.config import settings  # noqa: E402
from app.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture()
def auth(client):
    """Fresh demo sandbox for every test."""
    token = client.post("/api/auth/login", json={"username": "ayesha",
                                                 "password": settings.DEMO_USER_PASSWORD}).json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    assert client.post("/api/sandbox/reset", headers=headers).status_code == 200
    return headers


class Phone:
    """A test client with an Ed25519 key (accepted for test tools; Android phones use P-256)."""

    key_type = "ed25519"

    def __init__(self, client, headers):
        self.client, self.headers = client, headers
        self.key, pub = self._make_key()
        r = client.post("/api/devices", headers=headers,
                        json={"name": "Test phone", "key_type": self.key_type, "public_key": base64.b64encode(pub).decode()})
        assert r.status_code == 201, r.text
        self.device_id = r.json()["id"]

    def _make_key(self):
        k = Ed25519PrivateKey.generate()
        return k, k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)

    def sign(self, text: str) -> str:
        return base64.b64encode(self.key.sign(text.encode())).decode()

    def verify(self, action_id: int):
        ch = self.client.get(f"/api/agent/actions/{action_id}/challenge", headers=self.headers)
        assert ch.status_code == 200, ch.text
        return self.client.post(f"/api/agent/actions/{action_id}/verify", headers=self.headers,
                                json={"device_id": self.device_id, "signature": self.sign(ch.json()["challenge"])})


class AndroidPhone(Phone):
    """Simulates an Android Keystore key: P-256, public key as SubjectPublicKeyInfo, SHA256withECDSA (DER)."""

    key_type = "p256"

    def _make_key(self):
        k = ec.generate_private_key(ec.SECP256R1())
        return k, k.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)

    def sign(self, text: str) -> str:
        return base64.b64encode(self.key.sign(text.encode(), ec.ECDSA(hashes.SHA256()))).decode()


@pytest.fixture()
def phone(client, auth):
    return Phone(client, auth)


@pytest.fixture()
def android(client, auth):
    return AndroidPhone(client, auth)
