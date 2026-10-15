"""
Standing instructions: recurring payments such as rent or monthly money for family.

The student sets them once. On the due day the daily monitor prepares the payment through the normal
pipeline (cheapest route, risk check, policy) and sends a "verify to complete" notification. Nothing is
paid until the student verifies, and a risky or blocked payment is never prepared silently.
"""

from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Payee, StandingInstruction, User
from app.services import audit, sandbox, verification


class StandingError(ValueError):
    pass


def view(db: Session, si: StandingInstruction) -> dict:
    payee = db.get(Payee, si.payee_id)
    return {"id": si.id, "recipient": payee.name if payee else None,
            "relationship": payee.relationship if payee else None, "amount": si.amount, "currency": si.currency,
            "day_of_month": si.day_of_month, "note": si.note, "active": si.active,
            "last_prepared_period": si.last_prepared_period,
            "rule": "Prepared automatically on the due day; paid only after you verify"}


def create(db: Session, user: User, *, recipient: str, amount: float, day_of_month: int,
           currency: str | None = None, note: str | None = None) -> StandingInstruction:
    payee = verification.find_user_payee(db, user.id, recipient)
    if payee is None:
        raise StandingError(f"'{recipient}' is not a saved recipient. Add them first.")
    if not 1 <= int(day_of_month) <= 28:
        raise StandingError("Choose a day between 1 and 28")
    if amount <= 0:
        raise StandingError("Amount must be positive")
    si = StandingInstruction(user_id=user.id, payee_id=payee.id, amount=float(amount),
                             currency=sandbox.check_currency(currency or user.study_currency),
                             day_of_month=int(day_of_month), note=note, active=True)
    db.add(si)
    db.flush()
    audit.record(db, user_id=user.id, actor="STUDENT", event="STANDING_INSTRUCTION_CREATED", tier="T0",
                 details={"id": si.id, "recipient": payee.name, "amount": si.amount, "currency": si.currency,
                          "day_of_month": si.day_of_month})
    return si


def set_active(db: Session, user: User, si_id: int, active: bool) -> StandingInstruction:
    si = db.get(StandingInstruction, si_id)
    if si is None or si.user_id != user.id:
        raise StandingError("Standing instruction not found")
    si.active = active
    audit.record(db, user_id=user.id, actor="STUDENT", event="STANDING_INSTRUCTION_" + ("RESUMED" if active else "PAUSED"),
                 tier="T0", details={"id": si.id})
    return si


def due(db: Session, user: User, today: date) -> list[StandingInstruction]:
    period = today.strftime("%Y-%m")
    rows = db.scalars(select(StandingInstruction).where(StandingInstruction.user_id == user.id,
                                                        StandingInstruction.active.is_(True))).all()
    return [si for si in rows if today.day >= si.day_of_month and si.last_prepared_period != period]


def prepare_due(db: Session, user: User, today: date) -> list[dict]:
    """Prepare every due instruction as a payment awaiting the student's verification."""
    from app.services import payments  # local import: payments imports this module's siblings

    out = []
    for si in due(db, user, today):
        payee = db.get(Payee, si.payee_id)
        si.last_prepared_period = today.strftime("%Y-%m")
        try:
            result = payments.send_remittance(db, user, session_id=f"schedule-{si.id}", initiated_by="SCHEDULE",
                                              recipient=payee.name, amount=si.amount, currency=si.currency)
        except (payments.PaymentError, sandbox.SandboxError) as e:
            from app.services.notify import notify

            notify(db, user.id, kind="LOW_BALANCE", title="Scheduled payment couldn't be prepared",
                   body=f"{si.amount:,.0f} {si.currency} to {payee.name}: {e}", data={"key": f"si:{si.id}:{si.last_prepared_period}"})
            result = {"status": "ERROR", "error": str(e)}
        out.append({"standing_instruction_id": si.id, "recipient": payee.name, **{k: result.get(k) for k in
                    ("status", "action_id", "summary", "error")}})
    return out
