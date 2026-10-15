import hashlib
import json
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import AuditLog

GENESIS = "0" * 64


def _digest(prev_hash: str, created_at: str, user_id, actor: str, event: str, tier, details: dict) -> str:
    payload = json.dumps([prev_hash, created_at, user_id, actor, event, tier, details], sort_keys=True, default=str)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def record(db: Session, *, user_id: int | None, actor: str, event: str, details: dict, tier: str | None = None) -> AuditLog:
    last = db.scalar(select(AuditLog).order_by(AuditLog.id.desc()).limit(1))
    prev_hash = last.hash if last else GENESIS
    now = datetime.now(timezone.utc)
    entry = AuditLog(user_id=user_id, actor=actor, event=event, tier=tier, details=details, prev_hash=prev_hash,
                     created_at=now, hash=_digest(prev_hash, now.isoformat(), user_id, actor, event, tier, details))
    db.add(entry)
    db.flush()
    return entry


def verify_chain(db: Session) -> dict:
    """Recompute every hash; returns the first broken row if the log was edited."""
    prev = GENESIS
    rows = db.scalars(select(AuditLog).order_by(AuditLog.id)).all()
    for row in rows:
        created = row.created_at if row.created_at.tzinfo else row.created_at.replace(tzinfo=timezone.utc)
        expected = _digest(prev, created.isoformat(), row.user_id, row.actor, row.event, row.tier, row.details)
        if row.prev_hash != prev or row.hash != expected:
            return {"valid": False, "entries": len(rows), "broken_at_id": row.id}
        prev = row.hash
    return {"valid": True, "entries": len(rows), "head": prev}
