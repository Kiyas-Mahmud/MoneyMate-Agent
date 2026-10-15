import base64
import os
import tempfile

import pytest

_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
os.environ["DATABASE_URL"] = f"sqlite:///{_db.name}"
os.environ["GEMINI_API_KEY"] = ""  # tests use the deterministic agent path
os.environ["FX_LIVE"] = "false"   # no network in tests; live FX is tested with a mocked HTTP call
os.environ["MONITOR_ENABLED"] = "false"  # the monitor is run explicitly in tests
os.environ["VERIFICATION_MODE"] = "device"
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-not-for-production")

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
    """Simulates the student's phone: a key pair whose private half would sit behind Face ID."""

    def __init__(self, client, headers):
        self.client, self.headers = client, headers
        self.key = Ed25519PrivateKey.generate()
        pub = self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        r = client.post("/api/devices", headers=headers,
                        json={"name": "Test phone", "public_key": base64.b64encode(pub).decode()})
        assert r.status_code == 201, r.text
        self.device_id = r.json()["id"]

    def sign(self, text: str) -> str:
        return base64.b64encode(self.key.sign(text.encode())).decode()

    def verify(self, action_id: int):
        ch = self.client.get(f"/api/agent/actions/{action_id}/challenge", headers=self.headers)
        assert ch.status_code == 200, ch.text
        return self.client.post(f"/api/agent/actions/{action_id}/verify", headers=self.headers,
                                json={"device_id": self.device_id, "signature": self.sign(ch.json()["challenge"])})


@pytest.fixture()
def phone(client, auth):
    return Phone(client, auth)
