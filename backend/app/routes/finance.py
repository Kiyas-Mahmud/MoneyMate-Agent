"""Direct (non-chat) API for the app screens. Same payment pipeline and policy as the agent."""

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user
from app.models import Payee, Transaction, TuitionInvoice, User
from app.services import anchor, audit, payments, receipts, reminders, sandbox, verification
from app.services.notify import notify
from app.services.seed import CURRENCY_BY_COUNTRY
from app.services.agent.second_opinion import analyze_with_second_opinion

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
    fx = sandbox.rates_info()
    return {"balances": bals, "total_usd": round(sum(b["usd_equivalent"] for b in bals), 2),
            "rates": fx["rates"], "rates_as_of": fx["as_of"], "rates_source": fx["source"]}


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


class PayeeIn(BaseModel):
    name: str = Field(min_length=2, max_length=160)
    relationship: str | None = Field(default=None, max_length=40)
    country: str = Field(min_length=2, max_length=60)
    bank_name: str | None = Field(default=None, max_length=120)
    account_ref: str = Field(min_length=6, max_length=64)


@router.post("/payees", status_code=201)
def add_payee(body: PayeeIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Saves a recipient (family, landlord...). It is unverified: the first payment still needs the fingerprint."""
    account = "".join(ch for ch in body.account_ref if ch.isalnum()).upper()
    if not 6 <= len(account) <= 34 or not any(ch.isdigit() for ch in account):
        raise HTTPException(400, "Enter the full account number")
    if body.country not in CURRENCY_BY_COUNTRY:
        raise HTTPException(400, f"Sending to {body.country} isn't supported yet")
    mine = db.scalars(select(Payee).where(Payee.owner_user_id == user.id)).all()
    if any("".join(ch for ch in p.account_ref if ch.isalnum()).upper() == account for p in mine):
        raise HTTPException(409, "You already saved this account")
    p = Payee(owner_user_id=user.id, name=body.name.strip(), kind="INDIVIDUAL",
              relationship=(body.relationship or "").strip().lower() or None, country=body.country,
              currency=CURRENCY_BY_COUNTRY[body.country], bank_name=(body.bank_name or "").strip() or None,
              account_ref=account, verified=False)
    db.add(p)
    db.flush()
    audit.record(db, user_id=user.id, actor="STUDENT", event="PAYEE_ADDED",
                 details={"payee_id": p.id, "name": p.name, "country": p.country, "account_hint": account[-4:]})
    notify(db, user.id, kind="PAYEE_ADDED", title="New recipient saved",
           body=f"{p.name} (****{account[-4:]}) was added. If this wasn't you, change your password right away.")
    db.commit()
    return {"id": p.id, "name": p.name, "kind": p.kind, "relationship": p.relationship, "country": p.country,
            "currency": p.currency, "bank_name": p.bank_name, "account_hint": "****" + account[-4:],
            "verified": p.verified}


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
                    "account_hint": "****" + payee.account_ref[-4:], "transaction_id": inv.transaction_id})
    return out


@router.get("/tuition/reminders")
def tuition_reminders(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    result = reminders.tuition_reminders(db, user)
    db.commit()
    return result


@router.post("/tuition/pay")
def pay_tuition(body: TuitionIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _guard(lambda: payments.pay_tuition(db, user, session_id="ui", initiated_by="USER",
                                               **body.model_dump(exclude_none=True)), db)


@router.post("/remittance/compare")
def compare(body: CompareIn, user: User = Depends(get_current_user)):
    try:
        fx = sandbox.rates_info()
        return {"options": sandbox.compare(body.amount, body.from_currency.upper(), body.to_currency.upper()),
                "rates_as_of": fx["as_of"], "rates_source": fx["source"]}
    except sandbox.SandboxError as e:
        raise HTTPException(400, str(e))


@router.post("/remittance/send")
def send(body: RemitIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _guard(lambda: payments.send_remittance(db, user, session_id="ui", initiated_by="USER",
                                                   **body.model_dump(exclude_none=True)), db)


@router.post("/scam-check")
def scam_check(body: TextIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return analyze_with_second_opinion(db, body.text)


def _own_tx(db: Session, user: User, tx_id: int) -> Transaction:
    tx = db.get(Transaction, tx_id)
    if tx is None or tx.user_id != user.id:
        raise HTTPException(404, "Transaction not found")
    return tx


@router.get("/transactions/{tx_id}/receipt")
def receipt(tx_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        tx = _own_tx(db, user, tx_id)
        r = receipts.build(db, tx)
        # Outside the signed fields: anchoring can happen after the receipt is issued.
        return {**r, "anchor": anchor.status_for(db, user.id, "PAYMENT_VERIFIED", "transaction_id", tx.id)}
    except receipts.ReceiptError as e:
        raise HTTPException(400, str(e))


@router.get("/transactions/{tx_id}/receipt.pdf")
def receipt_pdf(tx_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    tx = _own_tx(db, user, tx_id)
    try:
        content = receipts.pdf(db, tx)
    except receipts.ReceiptError as e:
        raise HTTPException(400, str(e))
    return Response(content, media_type="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="{receipts.reference(tx)}.pdf"'})


@router.get("/receipts/verify")
def verify_receipt(reference: str, code: str, db: Session = Depends(get_db)):
    """Public: lets a landlord, university or visa office check a receipt without logging in."""
    result = receipts.verify(db, reference, code)
    if result.get("valid"):
        tx = db.get(Transaction, receipts._id_from_reference(reference))
        result["anchor"] = anchor.status_for(db, tx.user_id, "PAYMENT_VERIFIED", "transaction_id", tx.id)
    return result


# ---- exchange rates and money requests to family --------------------------------------------------------
from app.services import funds  # noqa: E402


class FundRequestIn(BaseModel):
    payee_id: int
    amount: float = Field(gt=0)
    currency: str | None = None
    reason: str | None = Field(default=None, max_length=200)


class FundReceiveIn(BaseModel):
    provider_id: str


def _funds_guard(fn, db: Session):
    try:
        result = fn()
        db.commit()
        return result
    except (funds.FundsError, sandbox.SandboxError) as e:
        db.rollback()
        raise HTTPException(400, str(e))


@router.get("/fx/rates")
def fx_rates(user: User = Depends(get_current_user)):
    """Live mid-market rates between BDT, CNY and USD, with the best provider for each pair."""
    return funds.rates()


@router.get("/funds/family")
def funds_family(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return funds.family_members(db, user)


@router.get("/funds/quote")
def funds_quote(amount: float, currency: str | None = None, from_currency: str | None = None,
                user: User = Depends(get_current_user)):
    """What family must send, through each provider (cheapest first), for the student to receive `amount`."""
    try:
        dst = sandbox.check_currency(currency or user.study_currency)
        src = sandbox.check_currency(from_currency or user.home_currency)
    except sandbox.SandboxError as e:
        raise HTTPException(400, str(e))
    if amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    return {"options": funds.options(amount, src, dst)}


@router.get("/funds/requests")
def funds_requests(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    from app.models import FundRequest

    rows = db.scalars(select(FundRequest).where(FundRequest.user_id == user.id).order_by(FundRequest.id.desc())
                      .limit(20)).all()
    return [funds.view(db, r) for r in rows]


@router.post("/funds/requests", status_code=201)
def funds_request(body: FundRequestIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _funds_guard(lambda: funds.view(db, funds.create(db, user, payee_id=body.payee_id, amount=body.amount,
                                                             currency=body.currency, reason=body.reason)), db)


@router.post("/funds/requests/{request_id}/receive")
def funds_receive(request_id: int, body: FundReceiveIn, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)):
    """Sandbox: simulate the family's transfer arriving through the provider they used."""
    return _funds_guard(lambda: funds.view(db, funds.receive(db, user, request_id, body.provider_id)), db)


@router.post("/funds/requests/{request_id}/cancel")
def funds_cancel(request_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return _funds_guard(lambda: funds.view(db, funds.cancel(db, user, request_id)), db)
