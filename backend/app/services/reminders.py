"""
Tuition deadline reminders: 14, 7 and 3 days before the due date, and when overdue.
Each reminder also checks whether the student's wallet covers the invoice and, if not, what converting
from the home currency would cost today. A reminder stage is logged once per invoice in the audit log.
"""

from datetime import date, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Payee, TuitionInvoice, User
from app.services import audit, sandbox
from app.services.notify import notify

STAGES = [(-10_000, -1, "OVERDUE"), (0, 3, "DUE_IN_3_DAYS"), (4, 7, "DUE_IN_7_DAYS"), (8, 14, "DUE_IN_14_DAYS")]
STAGE_RANK = {None: 0, "DUE_IN_14_DAYS": 1, "DUE_IN_7_DAYS": 2, "DUE_IN_3_DAYS": 3, "OVERDUE": 4}


def _stage(days_left: int) -> str | None:
    return next((name for lo, hi, name in STAGES if lo <= days_left <= hi), None)


def _cost_to_cover(shortfall: float, src: str, dst: str) -> float:
    """Amount in `src` that must be converted (fee included) to receive `shortfall` in `dst`."""
    q = sandbox.quote(1000.0, src, dst, "remitlite")  # rate and fee for this pair
    return shortfall / q["rate"] + q["fee"]


def tuition_reminders(db: Session, user: User, today: date | None = None, log_new_stages: bool = True) -> list[dict]:
    today = today or datetime.now().date()
    invoices = db.scalars(select(TuitionInvoice).where(TuitionInvoice.user_id == user.id,
                                                       TuitionInvoice.status == "OPEN")
                          .order_by(TuitionInvoice.due_date)).all()
    out = []
    for inv in invoices:
        due = date.fromisoformat(inv.due_date)
        days_left = (due - today).days
        stage = _stage(days_left)
        wallet = sandbox.get_wallet(db, user.id, inv.currency)
        have = wallet.balance if wallet else 0.0
        shortfall = max(inv.amount - have, 0.0)
        uni = db.get(Payee, inv.payee_id)

        when = (f"was due {-days_left} day{'s' if days_left != -1 else ''} ago" if days_left < 0
                else "is due today" if days_left == 0 else f"is due in {days_left} day{'s' if days_left != 1 else ''}")
        msg = f"{inv.semester} tuition ({inv.amount:,.0f} {inv.currency}) {when} ({due:%d %b})."
        convert = None
        if shortfall > 0:
            src = user.home_currency if user.home_currency != inv.currency else "USD"
            cost = _cost_to_cover(shortfall, src, inv.currency)
            convert = {"from_currency": src, "amount": round(cost, 2), "to_currency": inv.currency,
                       "receives": round(shortfall, 2)}
            msg += (f" Your {inv.currency} wallet is short by {shortfall:,.0f} {inv.currency}; converting about "
                    f"{cost:,.0f} {src} today would cover it (fees included).")
        else:
            msg += f" Your {inv.currency} wallet covers it."
        if stage:
            msg += " Pay on time to avoid late fees or an enrolment hold."

        if log_new_stages and stage and STAGE_RANK[stage] > STAGE_RANK[inv.last_reminder_stage]:
            inv.last_reminder_stage = stage
            audit.record(db, user_id=user.id, actor="AGENT", event="TUITION_REMINDER", tier="T0",
                         details={"invoice_id": inv.id, "stage": stage, "days_left": days_left,
                                  "shortfall": round(shortfall, 2), "currency": inv.currency})
            notify(db, user.id, kind="TUITION_REMINDER",
                   title=("Tuition overdue" if stage == "OVERDUE" else
                          f"Tuition due in {days_left} day{'s' if days_left != 1 else ''}"),
                   body=msg, data={"invoice_id": inv.id, "stage": stage, "shortfall": round(shortfall, 2),
                                   "convert_suggestion": convert})

        out.append({
            "invoice_id": inv.id, "semester": inv.semester, "university": uni.name if uni else None,
            "amount": inv.amount, "currency": inv.currency, "due_date": inv.due_date, "days_left": days_left,
            "stage": stage, "alert": stage is not None, "wallet_balance": round(have, 2),
            "covered": shortfall == 0, "shortfall": round(shortfall, 2), "convert_suggestion": convert,
            "message": msg,
        })
    return out
