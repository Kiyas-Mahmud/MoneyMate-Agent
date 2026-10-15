from datetime import datetime

from sqlalchemy import JSON, DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class AgentAction(Base):
    """Every tool the agent calls. Money-moving actions wait here until the student confirms in the UI."""

    __tablename__ = "agent_actions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    session_id: Mapped[str] = mapped_column(String(40), index=True)
    tool: Mapped[str] = mapped_column(String(60))
    args: Mapped[dict] = mapped_column(JSON)
    tier: Mapped[str] = mapped_column(String(4))
    # READ | AWAITING_VERIFICATION | VERIFIED | REJECTED | BLOCKED | EXPIRED
    status: Mapped[str] = mapped_column(String(24), index=True)
    summary: Mapped[str | None] = mapped_column(String(300))
    transaction_id: Mapped[int | None] = mapped_column(ForeignKey("transactions.id"))
    result: Mapped[dict | None] = mapped_column(JSON)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    verification_nonce: Mapped[str | None] = mapped_column(String(64))  # one-time challenge for the device
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class ChatMessage(Base):
    __tablename__ = "chat_messages"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    session_id: Mapped[str] = mapped_column(String(40), index=True)
    role: Mapped[str] = mapped_column(String(10))  # user | assistant
    content: Mapped[str] = mapped_column(Text)
    action_ids: Mapped[list | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AuditLog(Base):
    """Append-only, hash-chained log: each row stores the hash of the previous one, so edits are detectable."""

    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"), index=True)
    actor: Mapped[str] = mapped_column(String(10))  # STUDENT | AGENT | SYSTEM
    event: Mapped[str] = mapped_column(String(60), index=True)
    tier: Mapped[str | None] = mapped_column(String(4))
    details: Mapped[dict] = mapped_column(JSON)
    prev_hash: Mapped[str] = mapped_column(String(64))
    hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Device(Base):
    """A student's phone. Its private key never leaves the device and is unlocked by Face ID / fingerprint."""

    __tablename__ = "devices"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    public_key: Mapped[str] = mapped_column(String(120))  # base64 Ed25519 public key (32 bytes)
    push_token: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Notification(Base):
    __tablename__ = "notifications"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    # VERIFY_PAYMENT | PAYMENT_DONE | PAYMENT_BLOCKED | TUITION_REMINDER | MULE_ALERT | LOW_BALANCE
    kind: Mapped[str] = mapped_column(String(24), index=True)
    title: Mapped[str] = mapped_column(String(120))
    body: Mapped[str] = mapped_column(String(400))
    action_id: Mapped[int | None] = mapped_column(ForeignKey("agent_actions.id"))
    data: Mapped[dict | None] = mapped_column(JSON)
    read: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
