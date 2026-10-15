"""No money moves without the student's verification; standing instructions; daily monitor; notifications."""

from datetime import date, datetime, timedelta, timezone

from sqlalchemy import update

from app.core.config import settings
from app.core.database import SessionLocal
from app.models import AgentAction
from tests.conftest import Phone
from tests.test_scenarios import balance, chat, money_action


def prepared(client, auth, msg="send 400 CNY to mother"):
    act = money_action(chat(client, auth, msg))
    assert act["status"] == "AWAITING_VERIFICATION"
    return act


def test_no_signature_no_payment(client, auth, phone):
    act = prepared(client, auth)
    r = client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth, json={})
    assert r.status_code == 403
    assert balance(client, auth, "CNY") == 18000


def test_wrong_signature_is_rejected(client, auth, phone):
    act = prepared(client, auth)
    sig = phone.sign(f"moneymate-verify:{act['action_id']}:not-the-real-nonce")
    r = client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth,
                    json={"device_id": phone.device_id, "signature": sig})
    assert r.status_code == 403


def test_another_users_phone_cannot_verify(client, auth, phone):
    act = prepared(client, auth)
    other = client.post("/api/auth/register", json={"username": "otherphone1", "password": "Other#2026x",
                                                    "full_name": "Other"}).json()["access_token"]
    other_phone = Phone(client, {"Authorization": f"Bearer {other}"})
    ch = client.get(f"/api/agent/actions/{act['action_id']}/challenge", headers=auth).json()["challenge"]
    r = client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth,
                    json={"device_id": other_phone.device_id, "signature": other_phone.sign(ch)})
    assert r.status_code == 403


def test_signature_cannot_be_replayed(client, auth, phone):
    act = prepared(client, auth)
    ch = client.get(f"/api/agent/actions/{act['action_id']}/challenge", headers=auth).json()["challenge"]
    body = {"device_id": phone.device_id, "signature": phone.sign(ch)}
    assert client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth, json=body).status_code == 200
    assert client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth, json=body).status_code == 400


def test_expired_request_cannot_be_verified(client, auth, phone):
    act = prepared(client, auth)
    with SessionLocal() as db:
        db.execute(update(AgentAction).where(AgentAction.id == act["action_id"])
                   .values(expires_at=datetime.now(timezone.utc) - timedelta(minutes=1)))
        db.commit()
    r = client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth,
                    json={"device_id": phone.device_id, "signature": "AAAA"})
    assert r.status_code == 400 and "expired" in r.json()["detail"]


def test_student_can_reject(client, auth, phone):
    act = prepared(client, auth)
    r = client.post(f"/api/agent/actions/{act['action_id']}/reject", headers=auth)
    assert r.status_code == 200 and r.json()["status"] == "REJECTED"
    assert balance(client, auth, "CNY") == 18000


def test_conversion_also_needs_verification(client, auth, phone):
    act = money_action(chat(client, auth, "convert 20000 BDT to CNY"))
    assert act["status"] == "AWAITING_VERIFICATION"
    assert balance(client, auth, "BDT") == 250000
    assert phone.verify(act["action_id"]).status_code == 200
    assert balance(client, auth, "BDT") == 230000 and balance(client, auth, "CNY") > 18000


def test_sandbox_mode_only_when_enabled(client, auth, monkeypatch):
    act = prepared(client, auth)
    r = client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth, json={"sandbox": True})
    assert r.status_code == 403                                          # device mode by default
    monkeypatch.setattr(settings, "VERIFICATION_MODE", "sandbox")
    r = client.post(f"/api/agent/actions/{act['action_id']}/verify", headers=auth, json={"sandbox": True})
    assert r.status_code == 200


def test_standing_instruction_is_prepared_on_due_day_and_waits(client, auth, phone):
    first_of_next_month = (date.today().replace(day=28) + timedelta(days=4)).replace(day=1)
    run = client.post("/api/monitor/run", headers=auth, params={"day": first_of_next_month.isoformat()}).json()
    sched = run["scheduled_payments"]
    assert len(sched) == 1 and sched[0]["recipient"] == "Rokeya Begum"
    assert sched[0]["status"] == "AWAITING_VERIFICATION"
    note = next(n for n in client.get("/api/notifications", headers=auth).json() if n["action_id"] == sched[0]["action_id"])
    assert note["body"].startswith("Scheduled payment ready") and "complete verification" in note["body"]
    assert balance(client, auth, "CNY") == 18000                         # nothing paid yet
    again = client.post("/api/monitor/run", headers=auth, params={"day": first_of_next_month.isoformat()}).json()
    assert again["scheduled_payments"] == []                             # not prepared twice
    assert phone.verify(sched[0]["action_id"]).json()["status"] == "VERIFIED"
    assert balance(client, auth, "CNY") == 16500


def test_create_standing_instruction_by_chat(client, auth):
    resp = chat(client, auth, "every month send 1000 CNY to father on 3rd")
    si = resp["actions"][0]["standing_instruction"]
    assert si["day_of_month"] == 3 and si["amount"] == 1000 and si["recipient"] == "Abdul Karim"
    assert len(client.get("/api/standing-instructions", headers=auth).json()) == 3


def test_money_from_stranger_triggers_mule_alert(client, auth):
    client.post("/api/sandbox/incoming", headers=auth,
                json={"sender": "Global Remote Jobs Ltd", "amount": 30000, "currency": "CNY"})
    kinds = [n["kind"] for n in client.get("/api/notifications", headers=auth).json()]
    assert "MULE_ALERT" in kinds
    run = client.post("/api/monitor/run", headers=auth).json()
    assert run["mule_alerts"] == 0                                        # already warned, no duplicate


def test_monitor_sends_tuition_reminder_once(client, auth):
    client.post("/api/monitor/run", headers=auth)
    client.post("/api/monitor/run", headers=auth)
    reminders = [n for n in client.get("/api/notifications", headers=auth).json() if n["kind"] == "TUITION_REMINDER"]
    assert len(reminders) == 1 and "short by 8,000 CNY" in reminders[0]["body"]


def test_notifications_can_be_marked_read(client, auth):
    prepared(client, auth)
    assert client.get("/api/notifications", headers=auth, params={"unread": True}).json()
    client.post("/api/notifications/read-all", headers=auth)
    assert client.get("/api/notifications", headers=auth, params={"unread": True}).json() == []
