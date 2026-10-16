from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user
from app.models import PaymentReport, User
from app.services import history

router = APIRouter(prefix="/history", tags=["payment history"])


class IssueIn(BaseModel):
    months: int = Field(default=6, ge=1, le=12)


@router.get("")
def preview(months: int = Query(default=6, ge=1, le=12), user: User = Depends(get_current_user),
            db: Session = Depends(get_db)):
    """The student's own on-time record for the last `months` months (not yet issued, no code)."""
    return history.build(db, user, months)


@router.post("/reports", status_code=201)
def issue(body: IssueIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Issue a verifiable report: a snapshot with a reference and a verification code."""
    rep = history.issue(db, user, body.months)
    db.commit()
    return history.view(rep)


@router.get("/reports")
def reports(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(PaymentReport).where(PaymentReport.user_id == user.id)
                      .order_by(PaymentReport.id.desc()).limit(10)).all()
    return [history.view(r) for r in rows]


@router.get("/reports/{reference}/pdf")
def report_pdf(reference: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rep = history.find(db, reference)
    if rep is None or rep.user_id != user.id:
        raise HTTPException(404, "Report not found")
    return Response(history.pdf(rep), media_type="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="{rep.reference}.pdf"'})


@router.get("/verify")
def verify(reference: str, code: str, db: Session = Depends(get_db)):
    """Public: anyone holding the reference and code can check the report is genuine. Summary only."""
    return history.verify(db, reference, code)
