from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.core.security import get_current_user
from app.models import AuditLog, User
from app.services import audit, payments, sandbox
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
    return audit.verify_chain(db)


@router.get("/risk/model")
def model_card():
    b = load_bundle()
    return {"version": b["version"], "base_models": b["base_model_names"], "meta_learner": "logistic_regression",
            "features": FEATURE_NAMES, "thresholds": b["thresholds"], "metrics": b["metrics"],
            "policy_limits": {"auto_execute_usd": settings.AUTO_EXECUTE_LIMIT_USD,
                              "auto_execute_daily_usd": settings.AUTO_EXECUTE_DAILY_LIMIT_USD,
                              "confirmation_ttl_minutes": settings.CONFIRMATION_TTL_MINUTES}}


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
