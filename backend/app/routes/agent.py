from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user
from app.models import AgentAction, ChatMessage, User
from app.services import devices, payments, sandbox
from app.services.agent import orchestrator

router = APIRouter(prefix="/agent", tags=["agent"])


class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=8000)
    session_id: str | None = Field(default=None, max_length=40)


@router.post("/chat")
def chat(body: ChatIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return orchestrator.chat(db, user, body.message, body.session_id)


@router.get("/sessions/{session_id}/messages")
def messages(session_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(ChatMessage).where(ChatMessage.user_id == user.id, ChatMessage.session_id == session_id)
                      .order_by(ChatMessage.id)).all()
    actions = {a.id: a for a in db.scalars(select(AgentAction).where(AgentAction.user_id == user.id,
                                                                    AgentAction.session_id == session_id)).all()}
    return [{"role": m.role, "content": m.content, "created_at": m.created_at.isoformat() if m.created_at else None,
             "actions": [{"tool": actions[i].tool, **(actions[i].result or {}), "status": actions[i].status,
                          "action_id": i}
                         for i in (m.action_ids or []) if i in actions]} for m in rows]


@router.get("/actions")
def list_actions(status: str | None = None, limit: int = 50, user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)):
    q = select(AgentAction).where(AgentAction.user_id == user.id)
    if status:
        q = q.where(AgentAction.status == status)
    rows = db.scalars(q.order_by(AgentAction.id.desc()).limit(min(limit, 200))).all()
    return [payments.action_view(a) for a in rows]


@router.get("/actions/{action_id}")
def get_action(action_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """One action, e.g. for the verify sheet opened from a notification."""
    a = db.get(AgentAction, action_id)
    if a is None or a.user_id != user.id:
        raise HTTPException(404, "Action not found")
    return payments.action_view(a)


class VerifyIn(BaseModel):
    device_id: int | None = None
    signature: str | None = Field(default=None, max_length=200)
    sandbox: bool = False


@router.get("/actions/{action_id}/challenge")
def challenge(action_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """The one-time text the phone signs after fingerprint / face unlock (Android BiometricPrompt)."""
    try:
        return payments.challenge(db, user, action_id)
    except payments.PaymentError as e:
        raise HTTPException(400, str(e))


@router.post("/actions/{action_id}/verify")
def verify(action_id: int, body: VerifyIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        result = payments.verify_action(db, user, action_id, device_id=body.device_id, signature=body.signature,
                                        sandbox_ok=body.sandbox)
        db.commit()
        return result
    except devices.VerificationError as e:
        db.rollback()
        raise HTTPException(403, str(e))
    except (payments.PaymentError, sandbox.SandboxError) as e:
        db.rollback()
        raise HTTPException(400, str(e))


@router.post("/actions/{action_id}/reject")
def reject(action_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        result = payments.reject_action(db, user, action_id)
        db.commit()
        return result
    except payments.PaymentError as e:
        db.rollback()
        raise HTTPException(400, str(e))
