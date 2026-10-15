"""Deadline reminders, payment receipts, live FX rates and the Gemini second opinion."""

from datetime import date

import pytest
from sqlalchemy import select, update

from app.core.config import settings
from app.core.database import SessionLocal
from app.models import AuditLog, Transaction
from app.services import reminders, sandbox
from app.services.agent import second_opinion as so
from tests.test_scenarios import FAKE_INVOICE, chat, money_action


# ---------- tuition deadline reminders ----------

def test_reminder_warns_and_shows_shortfall(client, auth):
    r = client.get("/api/tuition/reminders", headers=auth).json()[0]
    assert r["stage"] == "DUE_IN_7_DAYS" and r["alert"] is True     # demo invoice is due in 6 days
    assert r["covered"] is False and r["shortfall"] == 8000.0      # 26,000 due, 18,000 in the CNY wallet
    assert r["convert_suggestion"]["from_currency"] == "BDT"
    assert "short by 8,000 CNY" in r["message"]


def test_reminder_stage_is_logged_once(client, auth):
    client.get("/api/tuition/reminders", headers=auth)
    client.get("/api/tuition/reminders", headers=auth)
    rows = client.get("/api/audit", headers=auth).json()
    reset_at = next(x["id"] for x in rows if x["event"] == "SANDBOX_RESET")
    logged = [x for x in rows if x["event"] == "TUITION_REMINDER" and x["id"] > reset_at]
    assert len(logged) == 1


@pytest.mark.parametrize("days,stage", [(20, None), (14, "DUE_IN_14_DAYS"), (7, "DUE_IN_7_DAYS"),
                                        (3, "DUE_IN_3_DAYS"), (0, "DUE_IN_3_DAYS"), (-2, "OVERDUE")])
def test_reminder_stages(days, stage):
    assert reminders._stage(days) == stage


def test_agent_answers_deadline_question_without_paying(client, auth):
    resp = chat(client, auth, "When is my tuition due?")
    assert [a["tool"] for a in resp["actions"]] == ["get_tuition_reminders"]
    assert resp["reminders"] and resp["reminders"][0]["stage"] == "DUE_IN_7_DAYS"


# ---------- payment receipts ----------

def paid(client, auth, phone, message="send 500 CNY to mother"):
    act = money_action(chat(client, auth, message))
    r = phone.verify(act["action_id"])
    assert r.status_code == 200, r.text
    return r.json()["result"]["receipt"]


def test_completed_payment_gets_verifiable_receipt(client, auth, phone):
    rc = paid(client, auth, phone)
    assert rc["reference"].startswith("MM-") and rc["amount"] == 500.0
    assert rc["approval"] == "Verified by the student on their phone"
    ok = client.get("/api/receipts/verify", params={"reference": rc["reference"], "code": rc["verification_code"]})
    assert ok.json()["valid"] is True                                     # public: no auth header needed
    bad = client.get("/api/receipts/verify", params={"reference": rc["reference"], "code": "0000-0000-0000-0000"})
    assert bad.json()["valid"] is False


def test_altered_payment_invalidates_receipt(client, auth, phone):
    rc = paid(client, auth, phone)
    with SessionLocal() as db:
        db.execute(update(Transaction).where(Transaction.id == rc["transaction_id"]).values(amount=5000.0))
        db.commit()
    r = client.get("/api/receipts/verify", params={"reference": rc["reference"], "code": rc["verification_code"]})
    assert r.json()["valid"] is False


def test_receipt_pdf_and_no_receipt_before_verification(client, auth, phone):
    rc = paid(client, auth, phone, "send 300 CNY to mother")
    pdf = client.get(f"/api/transactions/{rc['transaction_id']}/receipt.pdf", headers=auth)
    assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")
    pending = money_action(chat(client, auth, "send 200 CNY to mother"))
    assert client.get(f"/api/transactions/{pending['transaction']['id']}/receipt", headers=auth).status_code == 400
    blocked = client.post("/api/tuition/pay", headers=auth, json={"request_text": FAKE_INVOICE}).json()
    assert client.get(f"/api/transactions/{blocked['transaction']['id']}/receipt", headers=auth).status_code == 400


def test_receipt_of_other_users_transaction_is_hidden(client, auth, phone):
    rc = paid(client, auth, phone, "send 300 CNY to mother")
    other = client.post("/api/auth/register", json={"username": "snoop2026", "password": "Snoop#2026x",
                                                    "full_name": "Snoop"}).json()["access_token"]
    r = client.get(f"/api/transactions/{rc['transaction_id']}/receipt", headers={"Authorization": f"Bearer {other}"})
    assert r.status_code == 404


# ---------- live exchange rates ----------

@pytest.fixture()
def live_fx(monkeypatch):
    monkeypatch.setattr(settings, "FX_LIVE", True)
    monkeypatch.setitem(sandbox._fx, "rates", None)
    monkeypatch.setitem(sandbox._fx, "fetched_at", 0.0)
    monkeypatch.setitem(sandbox._fx, "failed_at", 0.0)


def test_live_rates_are_used_when_api_works(monkeypatch, live_fx):
    class FakeResp:
        def raise_for_status(self): pass
        def json(self):
            return {"result": "success", "time_last_update_utc": "Thu, 15 Oct 2026 00:02:31 +0000",
                    "rates": {"USD": 1, "BDT": 123.5, "CNY": 6.7, "CAD": 1.42, "GBP": 0.76, "MYR": 4.08, "EUR": 0.89}}
    monkeypatch.setattr(sandbox.httpx, "get", lambda *a, **k: FakeResp())
    info = sandbox.rates_info()
    assert info["source"].startswith("live") and info["rates"]["BDT"] == 123.5


def test_snapshot_used_when_api_is_down(monkeypatch, live_fx):
    def boom(*a, **k):
        raise sandbox.httpx.ConnectError("offline")
    monkeypatch.setattr(sandbox.httpx, "get", boom)
    info = sandbox.rates_info()
    assert info["source"].startswith("sandbox") and info["rates"] == sandbox.SANDBOX_RATES


# ---------- Gemini second opinion ----------

BENIGN_BUT_SCAM = "Hi, I'm a recruiter. Receive 3000 USD from our client into your account and forward it to my partner, you keep 10%."


def test_second_opinion_unavailable_without_key(client, auth):
    r = client.post("/api/scam-check", headers=auth, json={"text": FAKE_INVOICE}).json()
    assert r["second_opinion"]["available"] is False and r["verdict"] == r["rule_verdict"] == "LIKELY_SCAM"


def test_second_opinion_can_escalate(client, auth, monkeypatch):
    monkeypatch.setattr(settings, "GEMINI_API_KEY", "test-key")
    so._cache.clear()
    monkeypatch.setattr(so, "_call_gemini", lambda text: {
        "verdict": "SCAM", "scam_type": "fake job / money mule", "confidence": 0.93,
        "explanation": "Receiving and forwarding money for a stranger is money laundering.",
        "red_flags": ["receive and forward", "keep a percentage"], "advice": "Do not accept the money."})
    r = client.post("/api/scam-check", headers=auth, json={"text": BENIGN_BUT_SCAM}).json()
    assert r["rule_verdict"] != "LIKELY_SCAM"
    assert r["verdict"] == "LIKELY_SCAM" and r["escalated_by_second_opinion"] is True


def test_second_opinion_never_downgrades(client, auth, monkeypatch):
    monkeypatch.setattr(settings, "GEMINI_API_KEY", "test-key")
    so._cache.clear()
    monkeypatch.setattr(so, "_call_gemini", lambda text: {
        "verdict": "LOOKS_LEGITIMATE", "scam_type": "none", "confidence": 0.9, "explanation": "Looks fine.",
        "red_flags": [], "advice": "Pay it."})
    r = client.post("/api/scam-check", headers=auth, json={"text": FAKE_INVOICE}).json()
    assert r["verdict"] == "LIKELY_SCAM"


def test_second_opinion_failure_falls_back_to_rules(client, auth, monkeypatch):
    monkeypatch.setattr(settings, "GEMINI_API_KEY", "test-key")
    so._cache.clear()

    def fail(text):
        raise RuntimeError("quota exceeded")
    monkeypatch.setattr(so, "_call_gemini", fail)
    r = client.post("/api/scam-check", headers=auth, json={"text": FAKE_INVOICE}).json()
    assert r["second_opinion"]["available"] is False and r["verdict"] == "LIKELY_SCAM"
