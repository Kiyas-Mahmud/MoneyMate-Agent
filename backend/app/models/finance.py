from datetime import datetime

from sqlalchemy import JSON, Boolean, DateTime, Float, ForeignKey, String, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class Wallet(Base):
    """Sandbox multi-currency balance. No real money is held."""

    __tablename__ = "wallets"
    __table_args__ = (UniqueConstraint("user_id", "currency"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    currency: Mapped[str] = mapped_column(String(3))
    balance: Mapped[float] = mapped_column(Float, default=0.0)


class Payee(Base):
    """
    owner_user_id NULL  -> entry in the verified institution registry (official accounts)
    owner_user_id set   -> a payee the student added themselves (family, landlord, ...)
    """

    __tablename__ = "payees"

    id: Mapped[int] = mapped_column(primary_key=True)
    owner_user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(160))
    kind: Mapped[str] = mapped_column(String(20))  # INSTITUTION | INDIVIDUAL | BUSINESS
    relationship: Mapped[str | None] = mapped_column(String(40))  # mother, father, landlord ...
    country: Mapped[str] = mapped_column(String(60))
    currency: Mapped[str] = mapped_column(String(3))
    bank_name: Mapped[str | None] = mapped_column(String(120))
    account_ref: Mapped[str] = mapped_column(String(64), index=True)
    verified: Mapped[bool] = mapped_column(Boolean, default=False)
    verification_source: Mapped[str | None] = mapped_column(String(160))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class TuitionInvoice(Base):
    """Invoice synced from the university's official portal (seeded in the sandbox)."""

    __tablename__ = "tuition_invoices"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    payee_id: Mapped[int] = mapped_column(ForeignKey("payees.id"))
    semester: Mapped[str] = mapped_column(String(40))
    amount: Mapped[float] = mapped_column(Float)
    currency: Mapped[str] = mapped_column(String(3))
    due_date: Mapped[str] = mapped_column(String(10))
    status: Mapped[str] = mapped_column(String(12), default="OPEN")  # OPEN | PAID
    transaction_id: Mapped[int | None] = mapped_column(ForeignKey("transactions.id"))
    last_reminder_stage: Mapped[str | None] = mapped_column(String(20))


class Transaction(Base):
    __tablename__ = "transactions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    kind: Mapped[str] = mapped_column(String(20))  # TUITION | REMITTANCE_OUT | REMITTANCE_IN | CARD | FX
    direction: Mapped[str] = mapped_column(String(3))  # OUT | IN
    amount: Mapped[float] = mapped_column(Float)
    currency: Mapped[str] = mapped_column(String(3))
    amount_usd: Mapped[float] = mapped_column(Float)
    payee_id: Mapped[int | None] = mapped_column(ForeignKey("payees.id"))
    counterparty: Mapped[str] = mapped_column(String(160))
    counterparty_account: Mapped[str | None] = mapped_column(String(64))
    channel: Mapped[str] = mapped_column(String(20), default="BANK_TRANSFER")
    provider: Mapped[str | None] = mapped_column(String(60))
    fee: Mapped[float] = mapped_column(Float, default=0.0)
    fx_rate: Mapped[float | None] = mapped_column(Float)
    memo: Mapped[str | None] = mapped_column(String(300))

    # COMPLETED | AWAITING_CONFIRMATION | BLOCKED | REJECTED | EXPIRED
    status: Mapped[str] = mapped_column(String(24), index=True)
    risk_score: Mapped[float | None] = mapped_column(Float)
    risk_level: Mapped[str | None] = mapped_column(String(10))  # LOW | MEDIUM | HIGH
    risk_reasons: Mapped[list | None] = mapped_column(JSON)
    model_scores: Mapped[dict | None] = mapped_column(JSON)
    features: Mapped[dict | None] = mapped_column(JSON)
    tier: Mapped[str | None] = mapped_column(String(4))  # T0..T3
    initiated_by: Mapped[str] = mapped_column(String(10), default="USER")  # USER | AGENT | SANDBOX

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    executed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class StandingInstruction(Base):
    """A recurring payment the agent prepares on schedule (rent, money for family). Each one is verified."""

    __tablename__ = "standing_instructions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    payee_id: Mapped[int] = mapped_column(ForeignKey("payees.id"))
    amount: Mapped[float] = mapped_column(Float)
    currency: Mapped[str] = mapped_column(String(3))
    day_of_month: Mapped[int] = mapped_column()
    note: Mapped[str | None] = mapped_column(String(120))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    last_prepared_period: Mapped[str | None] = mapped_column(String(7))  # "2026-11"
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class PaymentReport(Base):
    """A payment history report the student issued (for a landlord, bank or university). The fields are a
    snapshot at issue time, so later payments don't change a report someone already received."""

    __tablename__ = "payment_reports"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    reference: Mapped[str | None] = mapped_column(String(32), unique=True, index=True)
    months: Mapped[int] = mapped_column()
    fields: Mapped[dict | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
