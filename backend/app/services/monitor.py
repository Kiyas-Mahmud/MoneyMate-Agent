"""
Daily monitor: the agent's own routine, run every morning without the student asking.

For each student it checks:
  1. tuition deadlines (14 / 7 / 3 days, overdue) and whether the wallet covers them
  2. standing instructions due today -> prepares them and asks the student to verify
  3. large money from first-time senders in the last 72 h (money-mule warning)
  4. low balance in the study currency for the payments coming up in the next 7 days

Every finding becomes a notification. Payments are only prepared, never executed: each one waits for the
student's verification on their phone.
"""

import asyncio
import logging
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import SessionLocal
from app.models import StandingInstruction, Transaction, User
from app.services import audit, payments, reminders, sandbox, standing
from app.services.notify import already_sent, notify

log = logging.getLogger(__name__)


def _low_balance(db: Session, user: User, today: date) -> dict | None:
    upcoming = []
    for si in db.scalars(select(StandingInstruction).where(StandingInstruction.user_id == user.id,
                                                           StandingInstruction.active.is_(True))).all():
        days = (si.day_of_month - today.day) % 31
        if 0 < days <= 7 and si.currency == user.study_currency:
            upcoming.append(si)
    need = sum(si.amount for si in upcoming)
    have = sandbox.get_wallet(db, user.id, user.study_currency)
    have = have.balance if have else 0.0
    key = f"low:{today.isoformat()}"
    if need and have < need and not already_sent(db, user.id, "LOW_BALANCE", key):
        notify(db, user.id, kind="LOW_BALANCE", title=f"Low {user.study_currency} balance",
               body=(f"Payments due this week need {need:,.0f} {user.study_currency}; you have {have:,.0f}. "
                     f"Convert from {user.home_currency} before they're due."),
               data={"key": key, "need": need, "have": round(have, 2)})
        return {"need": need, "have": round(have, 2)}
    return None


def run_for_user(db: Session, user: User, today: date | None = None) -> dict:
    today = today or datetime.now().date()
    summary = {"user": user.username, "date": today.isoformat()}

    summary["tuition_reminders"] = [{"semester": r["semester"], "stage": r["stage"], "shortfall": r["shortfall"]}
                                    for r in reminders.tuition_reminders(db, user, today=today) if r["alert"]]
    summary["scheduled_payments"] = standing.prepare_due(db, user, today)

    alerts = 0
    since = datetime.now(timezone.utc) - timedelta(hours=72)
    for tx in db.scalars(select(Transaction).where(Transaction.user_id == user.id, Transaction.direction == "IN",
                                                   Transaction.status == "COMPLETED",
                                                   Transaction.created_at >= since)).all():
        if payments.maybe_mule_alert(db, user, tx):
            alerts += 1
    summary["mule_alerts"] = alerts
    summary["low_balance"] = _low_balance(db, user, today)

    audit.record(db, user_id=user.id, actor="AGENT", event="DAILY_MONITOR_RUN", tier="T0",
                 details={"date": today.isoformat(), "reminders": len(summary["tuition_reminders"]),
                          "scheduled": len(summary["scheduled_payments"]), "mule_alerts": alerts,
                          "low_balance": bool(summary["low_balance"])})
    return summary


def run_all(today: date | None = None) -> list[dict]:
    out = []
    with SessionLocal() as db:
        for user in db.scalars(select(User).where(User.is_active.is_(True))).all():
            try:
                out.append(run_for_user(db, user, today))
                db.commit()
            except Exception:
                db.rollback()
                log.exception("Daily monitor failed for user %s", user.id)
    return out


def _seconds_until_next_run(now: datetime) -> float:
    target = now.replace(hour=settings.MONITOR_HOUR, minute=0, second=0, microsecond=0)
    if target <= now:
        target += timedelta(days=1)
    return (target - now).total_seconds()


async def scheduler():
    """Background loop started with the app: runs the monitor every day at MONITOR_HOUR."""
    while True:
        await asyncio.sleep(_seconds_until_next_run(datetime.now()))
        try:
            results = await asyncio.to_thread(run_all)
            log.info("Daily monitor ran for %d students", len(results))
        except Exception:
            log.exception("Daily monitor run failed")
