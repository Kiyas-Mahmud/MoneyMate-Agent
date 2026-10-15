"""Sandbox seed data: verified institution registry, demo student, wallets, recipients and history."""

import random
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.security import hash_password
from app.models import AgentAction, ChatMessage, Payee, Transaction, TuitionInvoice, User, Wallet
from app.services import audit, sandbox

# Fictional institutions; account numbers are sandbox values.
REGISTRY = [
    {"name": "Pearl River University (Shenzhen)", "country": "China", "currency": "CNY",
     "bank_name": "Bank of China, Shenzhen Branch", "account_ref": "6217000088123301"},
    {"name": "Northbridge University (Toronto)", "country": "Canada", "currency": "CAD",
     "bank_name": "Royal Bank of Canada", "account_ref": "003000124587761"},
    {"name": "Kingsgate University (London)", "country": "United Kingdom", "currency": "GBP",
     "bank_name": "Barclays Bank UK", "account_ref": "GB29BARC20040481562901"},
    {"name": "Selangor Institute of Technology", "country": "Malaysia", "currency": "MYR",
     "bank_name": "Maybank Berhad", "account_ref": "514011209933"},
]
CURRENCY_BY_COUNTRY = {"China": "CNY", "Canada": "CAD", "United Kingdom": "GBP", "Malaysia": "MYR",
                       "Bangladesh": "BDT", "United States": "USD"}


def ensure_registry(db: Session):
    if db.scalar(select(Payee).where(Payee.owner_user_id.is_(None))):
        return
    for r in REGISTRY:
        db.add(Payee(owner_user_id=None, kind="INSTITUTION", verified=True,
                     verification_source="University official bursary page (sandbox registry)", **r))
    db.flush()


def _ago(days: float, hour: int = 8) -> datetime:  # hours are UTC (08:00 UTC = 14:00 Dhaka)
    d = datetime.now(timezone.utc) - timedelta(days=days)
    return d.replace(hour=hour, minute=random.randint(0, 59), second=0, microsecond=0)


def _hist(db, user, *, kind, direction, amount, currency, counterparty, days, payee=None, provider=None, hour=8):
    db.add(Transaction(user_id=user.id, kind=kind, direction=direction, amount=amount, currency=currency,
                       amount_usd=sandbox.to_usd(amount, currency), payee_id=payee.id if payee else None,
                       counterparty=counterparty, counterparty_account=payee.account_ref if payee else None,
                       channel="CARD" if kind == "CARD" else "BANK_TRANSFER", provider=provider, status="COMPLETED",
                       risk_score=round(random.uniform(0.01, 0.08), 3) if direction == "OUT" else None,
                       risk_level="LOW" if direction == "OUT" else None, tier="T1" if direction == "OUT" else "T0",
                       initiated_by="USER", created_at=_ago(days, hour), executed_at=_ago(days, hour)))


def provision_student(db: Session, user: User, with_history: bool):
    ensure_registry(db)
    user.home_currency = CURRENCY_BY_COUNTRY.get(user.home_country, "USD")
    user.study_currency = CURRENCY_BY_COUNTRY.get(user.study_country, "USD")
    uni = db.scalar(select(Payee).where(Payee.owner_user_id.is_(None), Payee.country == user.study_country))
    if uni:
        user.university_payee_id = uni.id
        user.student_id = user.student_id or f"S{2026}{user.id:05d}"

    home, study = user.home_currency, user.study_currency
    for cur, amt in {home: 250_000 if home == "BDT" else 2_000, study: 38_000 if study == "CNY" else 6_000,
                     "USD": 300}.items():
        if not sandbox.get_wallet(db, user.id, cur):
            db.add(Wallet(user_id=user.id, currency=cur, balance=float(amt)))

    mother = Payee(owner_user_id=user.id, name="Rokeya Begum", kind="INDIVIDUAL", relationship="mother",
                   country=user.home_country, currency=home, bank_name="Sonali Bank", account_ref="0102034455667",
                   verified=False)
    father = Payee(owner_user_id=user.id, name="Abdul Karim", kind="INDIVIDUAL", relationship="father",
                   country=user.home_country, currency=home, bank_name="BRAC Bank", account_ref="1501204477889",
                   verified=False)
    landlord = Payee(owner_user_id=user.id, name="Li Wei", kind="INDIVIDUAL", relationship="landlord",
                     country=user.study_country, currency=study, bank_name="ICBC", account_ref="6222020011223344",
                     verified=False)
    db.add_all([mother, father, landlord])
    db.flush()

    if uni:
        db.add(TuitionInvoice(user_id=user.id, payee_id=uni.id, semester="Spring 2027",
                              amount=26_000.0 if study == "CNY" else 9_500.0, currency=study, due_date="2026-11-05"))

    if not with_history:
        return
    random.seed(user.id)
    if uni:
        _hist(db, user, kind="TUITION", direction="OUT", amount=24_500.0 if study == "CNY" else 9_000.0,
              currency=study, counterparty=uni.name, payee=uni, days=128)
    for m in range(5):
        base = 5 + m * 30
        _hist(db, user, kind="REMITTANCE_IN", direction="IN", amount=60_000.0, currency=home,
              counterparty=father.name, days=base + 2)
        _hist(db, user, kind="REMITTANCE_OUT", direction="OUT", amount=1_500.0, currency=study,
              counterparty=mother.name, payee=mother, provider="RemitLite", days=base + 4)
        _hist(db, user, kind="REMITTANCE_OUT", direction="OUT", amount=2_800.0, currency=study,
              counterparty=landlord.name, payee=landlord, days=base + 1)
        for _ in range(4):
            _hist(db, user, kind="CARD", direction="OUT", amount=float(random.randint(40, 420)), currency=study,
                  counterparty=random.choice(["Campus canteen", "Meituan", "Didi", "Walmart Nanshan", "China Mobile"]),
                  days=base + random.uniform(0, 28), hour=random.randint(3, 14))


def _wipe(db: Session, user: User):
    uid = user.id
    db.execute(delete(TuitionInvoice).where(TuitionInvoice.user_id == uid))
    db.execute(delete(AgentAction).where(AgentAction.user_id == uid))
    db.execute(delete(ChatMessage).where(ChatMessage.user_id == uid))
    db.execute(delete(Transaction).where(Transaction.user_id == uid))
    db.execute(delete(Wallet).where(Wallet.user_id == uid))
    db.execute(delete(Payee).where(Payee.owner_user_id == uid))
    db.flush()


def reset_demo(db: Session, user: User):
    """Restore a student's sandbox to the demo starting point (the audit log is kept; it is append-only)."""
    _wipe(db, user)
    provision_student(db, user, with_history=True)
    audit.record(db, user_id=user.id, actor="SYSTEM", event="SANDBOX_RESET", details={})


def seed(db: Session):
    ensure_registry(db)
    if not db.scalar(select(User).where(User.username == "ayesha")):
        user = User(username="ayesha", full_name="Ayesha Rahman", email="ayesha@student.example",
                    password_hash=hash_password(settings.DEMO_USER_PASSWORD), home_country="Bangladesh",
                    study_country="China", created_at=datetime.now(timezone.utc) - timedelta(days=200))
        db.add(user)
        db.flush()
        provision_student(db, user, with_history=True)
        audit.record(db, user_id=user.id, actor="SYSTEM", event="DEMO_USER_SEEDED", details={"username": "ayesha"})
    db.commit()
