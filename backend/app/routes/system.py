from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.core.security import get_current_user
from app.models import AuditLog, User
from app.services import anchor, audit, payments, sandbox
from app.services.risk.engine import load_bundle
from app.services.risk.features import FEATURE_NAMES
from app.services.seed import reset_demo

router = APIRouter(tags=["system"])


class IncomingIn(BaseModel):
    sender: str = Field(min_length=2, max_length=160)
    amount: float = Field(gt=0)
    currency: str
    note: str = ""


@router.get("/audit")
def audit_log(limit: int = 100, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(AuditLog).where(AuditLog.user_id == user.id)
                      .order_by(AuditLog.id.desc()).limit(min(limit, 500))).all()
    return [{"id": r.id, "actor": r.actor, "event": r.event, "tier": r.tier, "details": r.details,
             "hash": r.hash, "prev_hash": r.prev_hash, "created_at": r.created_at.isoformat()} for r in rows]


@router.get("/audit/verify")
def audit_verify(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """The hash chain, and every blockchain anchor compared with the log (fetched from the blockchain itself)."""
    return anchor.full_check(db)


@router.get("/anchors")
def anchors(db: Session = Depends(get_db)):
    """Public: where the audit log is anchored. Only hashes and transaction links, no personal data."""
    from app.models import Anchor

    rows = db.scalars(select(Anchor).order_by(Anchor.id.desc()).limit(50)).all()
    return {"enabled": settings.ANCHOR_ENABLED, "chain": anchor.chain_name(), "chain_id": settings.ANCHOR_CHAIN_ID,
            "wallet": anchor.wallet_address(), "explorer_url": settings.ANCHOR_EXPLORER_URL,
            "anchors": [anchor.view(a) for a in rows]}


@router.post("/anchors/run")
def anchor_run(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Anchor now instead of waiting for the daily run (sandbox demo). Also confirms anchors already sent."""
    if settings.ENVIRONMENT == "production":
        raise HTTPException(400, "Anchoring runs on its daily schedule in production")
    result = anchor.run(db)
    try:
        anchor.refresh(db)
    except anchor.AnchorError:
        pass
    db.commit()
    return result


@router.get("/risk/model")
def model_card():
    b = load_bundle()
    return {"version": b["version"], "base_models": b["base_model_names"], "meta_learner": "logistic_regression",
            "features": FEATURE_NAMES, "thresholds": b["thresholds"], "metrics": b["metrics"],
            "policy": {"auto_execute": "never: every payment needs the student's verification",
                       "verification": settings.VERIFICATION_MODE,
                       "verification_ttl_minutes": settings.CONFIRMATION_TTL_MINUTES,
                       "scheduled_verification_ttl_hours": settings.SCHEDULED_TTL_HOURS}}


@router.post("/sandbox/incoming")
def incoming(body: IncomingIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        result = payments.receive_transfer(db, user, sender=body.sender, amount=body.amount,
                                           currency=body.currency, note=body.note)
        db.commit()
        return result
    except sandbox.SandboxError as e:
        db.rollback()
        raise HTTPException(400, str(e))


@router.post("/sandbox/reset")
def reset(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    reset_demo(db, user)
    db.commit()
    return {"status": "reset"}
