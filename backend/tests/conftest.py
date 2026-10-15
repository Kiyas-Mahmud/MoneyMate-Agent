import os
import tempfile

import pytest

_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
os.environ["DATABASE_URL"] = f"sqlite:///{_db.name}"
os.environ["GEMINI_API_KEY"] = ""  # tests use the deterministic agent path
os.environ["FX_LIVE"] = "false"   # no network in tests; live FX is tested with a mocked HTTP call
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-not-for-production")

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
