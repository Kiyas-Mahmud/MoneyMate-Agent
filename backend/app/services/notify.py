"""In-app notifications, with best-effort push to the student's phones through the Expo push service."""

import logging

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Device, Notification

log = logging.getLogger(__name__)


def notify(db: Session, user_id: int, *, kind: str, title: str, body: str, action_id: int | None = None,
           data: dict | None = None) -> Notification:
    n = Notification(user_id=user_id, kind=kind, title=title, body=body, action_id=action_id, data=data or {})
    db.add(n)
    db.flush()
    if settings.PUSH_ENABLED:
        _push(db, user_id, n)
    return n


def _push(db: Session, user_id: int, n: Notification):
    tokens = [d.push_token for d in db.scalars(select(Device).where(Device.user_id == user_id)).all() if d.push_token]
    if not tokens:
        return
    messages = [{"to": t, "title": n.title, "body": n.body, "sound": "default",
                 "data": {"notification_id": n.id, "kind": n.kind, "action_id": n.action_id}} for t in tokens]
    try:
        httpx.post(settings.EXPO_PUSH_URL, json=messages, timeout=5.0)
    except Exception as e:  # push is best effort; the in-app notification is the source of truth
        log.warning("Push delivery failed: %s", e)


def view(n: Notification) -> dict:
    return {"id": n.id, "kind": n.kind, "title": n.title, "body": n.body, "action_id": n.action_id,
            "data": n.data, "read": n.read, "created_at": n.created_at.isoformat() if n.created_at else None}


def already_sent(db: Session, user_id: int, kind: str, key: str) -> bool:
    """De-duplicate monitor notifications by a key stored in data['key']."""
    rows = db.scalars(select(Notification).where(Notification.user_id == user_id, Notification.kind == kind)).all()
    return any((r.data or {}).get("key") == key for r in rows)
