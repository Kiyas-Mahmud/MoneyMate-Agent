"""In-app notifications, with best-effort push to the student's Android phones through Firebase Cloud Messaging."""

import logging
import threading

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Device, Notification

log = logging.getLogger(__name__)
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_creds = None
_creds_lock = threading.Lock()


def notify(db: Session, user_id: int, *, kind: str, title: str, body: str, action_id: int | None = None,
           data: dict | None = None) -> Notification:
    n = Notification(user_id=user_id, kind=kind, title=title, body=body, action_id=action_id, data=data or {})
    db.add(n)
    db.flush()
    if settings.PUSH_ENABLED:
        _push(db, user_id, n)
    return n


def _fcm_token() -> str:
    """OAuth2 access token for the FCM HTTP v1 API, from the Firebase service-account file."""
    global _creds
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account

    with _creds_lock:
        if _creds is None:
            _creds = service_account.Credentials.from_service_account_file(settings.FCM_SERVICE_ACCOUNT_FILE,
                                                                           scopes=[FCM_SCOPE])
        if not _creds.valid:
            _creds.refresh(Request())
        return _creds.token


def fcm_message(token: str, n: Notification) -> dict:
    # Payment requests use a high-priority channel so the "verify" prompt shows as a heads-up notification.
    channel = "payments" if n.kind in ("VERIFY_PAYMENT", "PAYMENT_BLOCKED", "MULE_ALERT") else "updates"
    return {"message": {
        "token": token,
        "notification": {"title": n.title, "body": n.body},
        "data": {"notification_id": str(n.id), "kind": n.kind, "action_id": str(n.action_id or "")},
        "android": {"priority": "high", "notification": {"channel_id": channel, "click_action": "OPEN_MONEYMATE"}},
    }}


def _push(db: Session, user_id: int, n: Notification):
    tokens = [d.push_token for d in db.scalars(select(Device).where(Device.user_id == user_id)).all() if d.push_token]
    if not tokens or not settings.FCM_PROJECT_ID:
        return
    url = f"https://fcm.googleapis.com/v1/projects/{settings.FCM_PROJECT_ID}/messages:send"
    try:
        headers = {"Authorization": f"Bearer {_fcm_token()}"}
        for t in tokens:
            httpx.post(url, json=fcm_message(t, n), headers=headers, timeout=5.0)
    except Exception as e:  # push is best effort; the in-app notification is the source of truth
        log.warning("Push delivery failed: %s", e)


def view(n: Notification) -> dict:
    return {"id": n.id, "kind": n.kind, "title": n.title, "body": n.body, "action_id": n.action_id,
            "data": n.data, "read": n.read, "created_at": n.created_at.isoformat() if n.created_at else None}


def already_sent(db: Session, user_id: int, kind: str, key: str) -> bool:
    """De-duplicate monitor notifications by a key stored in data['key']."""
    rows = db.scalars(select(Notification).where(Notification.user_id == user_id, Notification.kind == kind)).all()
    return any((r.data or {}).get("key") == key for r in rows)
