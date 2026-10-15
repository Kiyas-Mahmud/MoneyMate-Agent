"""Android specifics: Keystore P-256 keys and Firebase Cloud Messaging push."""

import base64

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from app.core.config import settings
from app.services import notify as notify_mod
from tests.test_scenarios import balance, chat, money_action


def test_android_keystore_p256_key_verifies_payment(client, auth, android):
    act = money_action(chat(client, auth, "send 400 CNY to mother"))
    r = android.verify(act["action_id"])
    assert r.status_code == 200 and r.json()["status"] == "VERIFIED"
    assert balance(client, auth, "CNY") == 17600


def test_p256_signature_for_other_payment_fails(client, auth, android):
    first = money_action(chat(client, auth, "send 100 CNY to mother"))
    second = money_action(chat(client, auth, "send 200 CNY to mother"))
    ch = client.get(f"/api/agent/actions/{first['action_id']}/challenge", headers=auth).json()["challenge"]
    r = client.post(f"/api/agent/actions/{second['action_id']}/verify", headers=auth,
                    json={"device_id": android.device_id, "signature": android.sign(ch)})
    assert r.status_code == 403


def test_wrong_curve_is_refused(client, auth):
    pub = ec.generate_private_key(ec.SECP384R1()).public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    r = client.post("/api/devices", headers=auth,
                    json={"name": "Odd phone", "key_type": "p256", "public_key": base64.b64encode(pub).decode()})
    assert r.status_code == 400


def test_new_phone_triggers_alert(client, auth, android):
    notes = client.get("/api/notifications", headers=auth).json()
    assert notes[0]["kind"] == "DEVICE_ADDED"


def test_push_token_can_be_rotated(client, auth, android):
    r = client.post(f"/api/devices/{android.device_id}/push-token", headers=auth, json={"push_token": "fcm-token-123456"})
    assert r.status_code == 200
    assert next(d for d in client.get("/api/devices", headers=auth).json() if d["id"] == android.device_id)["push"]


def test_fcm_push_sent_for_verify_request(client, auth, android, monkeypatch):
    client.post(f"/api/devices/{android.device_id}/push-token", headers=auth, json={"push_token": "fcm-token-abcdef"})
    sent = []
    monkeypatch.setattr(settings, "PUSH_ENABLED", True)
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "moneymate-demo")
    monkeypatch.setattr(notify_mod, "_fcm_token", lambda: "access-token")
    monkeypatch.setattr(notify_mod.httpx, "post", lambda url, json, headers, timeout: sent.append((url, json, headers)))
    act = money_action(chat(client, auth, "send 300 CNY to mother"))
    url, body, headers = next(s for s in sent if s[1]["message"]["data"]["kind"] == "VERIFY_PAYMENT"
                              and s[1]["message"]["token"] == "fcm-token-abcdef")  # every registered phone gets it
    assert url.endswith("/projects/moneymate-demo/messages:send") and headers["Authorization"] == "Bearer access-token"
    msg = body["message"]
    assert msg["token"] == "fcm-token-abcdef" and msg["data"]["action_id"] == str(act["action_id"])
    assert msg["android"]["priority"] == "high" and msg["android"]["notification"]["channel_id"] == "payments"
    assert "complete verification" in msg["notification"]["body"]


def test_push_failure_does_not_break_payment(client, auth, android, monkeypatch):
    client.post(f"/api/devices/{android.device_id}/push-token", headers=auth, json={"push_token": "fcm-token-zzzzzz"})
    monkeypatch.setattr(settings, "PUSH_ENABLED", True)
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "moneymate-demo")

    def boom():
        raise RuntimeError("no service account")
    monkeypatch.setattr(notify_mod, "_fcm_token", boom)
    act = money_action(chat(client, auth, "send 300 CNY to mother"))
    assert act["status"] == "AWAITING_VERIFICATION"
