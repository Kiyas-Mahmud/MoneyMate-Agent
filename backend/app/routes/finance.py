"""Direct (non-chat) API for the app screens. Same payment pipeline and policy as the agent."""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user
from app.models import Payee, Transaction, TuitionInvoice, User
from app.services import payments, sandbox, verification

router = APIRouter(tags=["finance"])


def _guard(fn, db: Session):
    try:
        result = fn()
        db.commit()
        return result
    except (payments.PaymentError, sandbox.SandboxError) as e:
        db.rollback()
        raise HTTPException(400, str(e))


class ConvertIn(BaseModel):
    amount: float = Field(gt=0)
    from_currency: str
    to_currency: str


class TuitionIn(BaseModel):
    amount: float | None = Field(default=None, gt=0)
    currency: str | None = None
    payee_name: str | None = None
    account_ref: str | None = None
    semester: str | None = None
    request_text: str | None = None


class RemitIn(BaseModel):
    recipient: str
    amount: float = Field(gt=0)
    currency: str | None = None
    receive_currency: str | None = None
    provider_id: str | None = None
    account_ref: str | None = None
    country: str | None = None
    channel: str = "BANK_TRANSFER"


class CompareIn(BaseModel):
    amount: float = Field(gt=0)
    from_currency: str
    to_currency: str


class TextIn(BaseModel):
    text: str = Field(min_length=3, max_length=8000)


class VerifyIn(BaseModel):
    name: str | None = None
    account_ref: str | None = None


@router.get("/wallet")
def wallet(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    bals = sandbox.balances(db, user.id)
    return {"balances": bals, "total_usd": round(sum(b["usd_equivalent"] for b in bals), 2),
            "rates": sandbox.USD_RATES, "rates_as_of": sandbox.RATES_AS_OF}


@router.post("/wallet/convert")
def convert(body: ConvertIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _guard(lambda: payments.convert_currency(db, user, session_id="ui", initiated_by="USER",
                                                    amount=body.amount, from_currency=body.from_currency,
                                                    to_currency=body.to_currency), db)


@router.get("/payees")
def payees(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    def view(p: Payee):
        return {"id": p.id, "name": p.name, "kind": p.kind, "relationship": p.relationship, "country": p.country,
                "currency": p.currency, "bank_name": p.bank_name, "account_hint": "****" + p.account_ref[-4:],
                "verified": p.verified}
    mine = db.scalars(select(Payee).where(Payee.owner_user_id == user.id)).all()
    return {"recipients": [view(p) for p in mine], "registry": [view(p) for p in verification.registry(db)]}


@router.post("/payees/verify")
def verify(body: VerifyIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return verification.verify_payee(db, body.name, body.account_ref)


@router.get("/transactions")
def transactions(limit: int = 50, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Transaction).where(Transaction.user_id == user.id)
                      .order_by(Transaction.created_at.desc(), Transaction.id.desc()).limit(min(limit, 200))).all()
    return [payments.tx_view(t) for t in rows]


@router.get("/tuition/invoices")
def invoices(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(TuitionInvoice).where(TuitionInvoice.user_id == user.id)
                      .order_by(TuitionInvoice.due_date)).all()
    out = []
    for inv in rows:
        payee = db.get(Payee, inv.payee_id)
        out.append({"id": inv.id, "semester": inv.semester, "amount": inv.amount, "currency": inv.currency,
                    "due_date": inv.due_date, "status": inv.status, "university": payee.name,
                    "account_hint": "****" + payee.account_ref[-4:]})
    return out


@router.post("/tuition/pay")
def pay_tuition(body: TuitionIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _guard(lambda: payments.pay_tuition(db, user, session_id="ui", initiated_by="USER",
                                               **body.model_dump(exclude_none=True)), db)


@router.post("/remittance/compare")
def compare(body: CompareIn, user: User = Depends(get_current_user)):
    try:
        return {"options": sandbox.compare(body.amount, body.from_currency.upper(), body.to_currency.upper()),
                "rates_as_of": sandbox.RATES_AS_OF}
    except sandbox.SandboxError as e:
        raise HTTPException(400, str(e))


@router.post("/remittance/send")
def send(body: RemitIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _guard(lambda: payments.send_remittance(db, user, session_id="ui", initiated_by="USER",
                                                   **body.model_dump(exclude_none=True)), db)


@router.post("/scam-check")
def scam_check(body: TextIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return verification.analyze_request(db, body.text)


@router.get("/credit/passport")
def passport(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return payments.credit_passport(db, user)
