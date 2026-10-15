"""Phone enrolment, notifications, standing instructions and the daily monitor."""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.core.security import get_current_user
from app.models import Device, Notification, StandingInstruction, User
from app.services import audit, devices, monitor, sandbox, standing
from app.services.notify import view as notification_view

router = APIRouter(tags=["mobile"])


class DeviceIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    public_key: str = Field(min_length=40, max_length=120)
    push_token: str | None = Field(default=None, max_length=200)


class StandingIn(BaseModel):
    recipient: str
    amount: float = Field(gt=0)
    day_of_month: int = Field(ge=1, le=28)
    currency: str | None = None
    note: str | None = Field(default=None, max_length=120)


@router.post("/devices", status_code=201)
def register_device(body: DeviceIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        d = devices.register(db, user, body.name, body.public_key, body.push_token)
    except devices.VerificationError as e:
        raise HTTPException(400, str(e))
    audit.record(db, user_id=user.id, actor="STUDENT", event="DEVICE_REGISTERED", details={"device_id": d.id, "name": d.name})
    db.commit()
    return {"id": d.id, "name": d.name}


@router.get("/devices")
def list_devices(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Device).where(Device.user_id == user.id)).all()
    return [{"id": d.id, "name": d.name, "push": bool(d.push_token),
             "last_used_at": d.last_used_at.isoformat() if d.last_used_at else None} for d in rows]


@router.get("/notifications")
def notifications(unread: bool = False, limit: int = 50, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)):
    q = select(Notification).where(Notification.user_id == user.id)
    if unread:
        q = q.where(Notification.read.is_(False))
    rows = db.scalars(q.order_by(Notification.id.desc()).limit(min(limit, 200))).all()
    return [notification_view(n) for n in rows]


@router.post("/notifications/{nid}/read")
def read_one(nid: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    n = db.get(Notification, nid)
    if n is None or n.user_id != user.id:
        raise HTTPException(404, "Notification not found")
    n.read = True
    db.commit()
    return notification_view(n)


@router.post("/notifications/read-all")
def read_all(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    db.execute(update(Notification).where(Notification.user_id == user.id).values(read=True))
    db.commit()
    return {"status": "ok"}


@router.get("/standing-instructions")
def list_standing(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(StandingInstruction).where(StandingInstruction.user_id == user.id)).all()
    return [standing.view(db, si) for si in rows]


@router.post("/standing-instructions", status_code=201)
def create_standing(body: StandingIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        si = standing.create(db, user, **body.model_dump())
    except (standing.StandingError, sandbox.SandboxError) as e:
        db.rollback()
        raise HTTPException(400, str(e))
    db.commit()
    return standing.view(db, si)


@router.post("/standing-instructions/{si_id}/{action}")
def toggle_standing(si_id: int, action: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    if action not in ("pause", "resume"):
        raise HTTPException(404, "Unknown action")
    try:
        si = standing.set_active(db, user, si_id, action == "resume")
    except standing.StandingError as e:
        raise HTTPException(404, str(e))
    db.commit()
    return standing.view(db, si)


@router.post("/monitor/run")
def run_monitor(day: date | None = None, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Run today's agent routine now for the signed-in student. `day` simulates another date (sandbox)."""
    if day is not None and settings.ENVIRONMENT == "production":
        raise HTTPException(400, "Simulated dates are only available in the sandbox")
    result = monitor.run_for_user(db, user, day)
    db.commit()
    return result
