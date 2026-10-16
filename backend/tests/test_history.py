"""Payment history report: the on-time record a student can give a landlord, bank or university."""

from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from app.core.database import SessionLocal
from app.models import Payee, Transaction
from tests.test_scenarios import chat, money_action


def test_demo_history_counts_rent_family_and_tuition(client, auth):
    r = client.get("/api/history", headers=auth, params={"months": 6}).json()
    s = r["summary"]
    names = {c["name"]: c for c in r["categories"]}
    assert {"Rent", "Family support", "Tuition"} <= set(names)
    assert names["Tuition"] == {"name": "Tuition", "due": 1, "on_time": 1, "late": 0, "missed": 0}
    assert names["Rent"]["late"] == 1                       # one month rent was paid on the 10th, after the grace period
    assert s["late"] == 1 and s["missed"] == 0 and s["on_time"] == s["payments_due"] - 1
    assert s["on_time_rate"] == round(s["on_time"] * 100 / s["payments_due"])
    assert all(i["category"] != "Card" for i in r["items"])  # card spending is not part of the record
    assert all(i["account_hint"] is None or i["account_hint"].startswith("****") for i in r["items"])


def test_a_month_without_rent_is_missed(client, auth):
    now = datetime.now(timezone.utc)
    last_month = (now.replace(day=1) - timedelta(days=1)).strftime("%Y-%m")
    with SessionLocal() as db:
        landlord = db.scalar(select(Payee).where(Payee.relationship == "landlord", Payee.name == "Li Wei")
                             .order_by(Payee.id.desc()))
        rows = db.scalars(select(Transaction).where(Transaction.payee_id == landlord.id)).all()
        ids = [t.id for t in rows if t.executed_at.strftime("%Y-%m") == last_month]
        db.execute(delete(Transaction).where(Transaction.id.in_(ids)))
        db.commit()
    r = client.get("/api/history", headers=auth).json()
    missed = [i for i in r["items"] if i["status"] == "MISSED"]
    assert len(missed) == 1 and missed[0]["category"] == "Rent" and missed[0]["due_date"][:7] == last_month


def test_issued_report_verifies_and_hides_details_publicly(client, auth):
    rep = client.post("/api/history/reports", headers=auth, json={"months": 6}).json()
    assert rep["reference"].startswith("PH-") and len(rep["verification_code"]) == 19
    ok = client.get(rep["verify_url"]).json()                           # no login needed
    assert ok["valid"] is True and ok["report"]["issued_to"] == "Ayesha Rahman"
    assert ok["report"]["summary"]["on_time_rate"] == rep["summary"]["on_time_rate"]
    assert "items" not in ok["report"]                                  # payees and amounts stay private
    bad = client.get("/api/history/verify", params={"reference": rep["reference"], "code": "0000-0000-0000-0000"})
    assert bad.json()["valid"] is False
    assert client.get("/api/history/verify", params={"reference": "PH-20260101-999999", "code": "ABCD"}).json()["valid"] is False


def test_report_is_a_snapshot(client, auth, phone):
    rep = client.post("/api/history/reports", headers=auth, json={"months": 6}).json()
    act = money_action(chat(client, auth, "send 300 CNY to mother"))
    assert phone.verify(act["action_id"]).status_code == 200            # a new payment after the report
    assert client.get(rep["verify_url"]).json()["valid"] is True        # the issued report still checks out
    now = client.get("/api/history", headers=auth).json()
    assert len(now["items"]) == len(rep["items"]) + 1


def test_report_pdf_is_private_to_its_owner(client, auth):
    rep = client.post("/api/history/reports", headers=auth, json={"months": 3}).json()
    pdf = client.get(rep["pdf_path"], headers=auth)
    assert pdf.status_code == 200 and pdf.content[:4] == b"%PDF"
    other = client.post("/api/auth/register", json={"full_name": "Other Student", "username": "other_history",
                                                    "password": "password123", "home_country": "Bangladesh",
                                                    "study_country": "China"})
    token = (other.json() if other.status_code == 201 else client.post(
        "/api/auth/login", json={"username": "other_history", "password": "password123"}).json())["access_token"]
    assert client.get(rep["pdf_path"], headers={"Authorization": f"Bearer {token}"}).status_code == 404
    assert client.get("/api/history/reports", headers={"Authorization": f"Bearer {token}"}).json() == []


def test_new_student_has_an_empty_record(client):
    r = client.post("/api/auth/register", json={"full_name": "New Student", "username": "new_history",
                                                "password": "password123", "home_country": "Bangladesh",
                                                "study_country": "China"})
    token = (r.json() if r.status_code == 201 else client.post(
        "/api/auth/login", json={"username": "new_history", "password": "password123"}).json())["access_token"]
    rec = client.get("/api/history", headers={"Authorization": f"Bearer {token}"}).json()
    assert rec["summary"]["payments_due"] == 0 and rec["summary"]["on_time_rate"] is None
    assert any(u["category"].startswith("Tuition") for u in rec["upcoming"])


def test_history_needs_a_login(client):
    assert client.get("/api/history").status_code in (401, 403)
    assert client.post("/api/history/reports", json={"months": 6}).status_code in (401, 403)


def test_agent_explains_the_payment_record(client, auth):
    resp = chat(client, auth, "My landlord wants proof that I pay rent on time")
    assert [a["tool"] for a in resp["actions"]] == ["get_payment_history"]
    assert "on time" in resp["reply"] and "Payment history" in resp["reply"] and "not a credit score" in resp["reply"]
