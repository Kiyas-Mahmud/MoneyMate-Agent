from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(50), unique=True, index=True)
    email: Mapped[str | None] = mapped_column(String(120))
    password_hash: Mapped[str] = mapped_column(String(255))
    full_name: Mapped[str | None] = mapped_column(String(120))
    role: Mapped[str] = mapped_column(String(20), default="STUDENT")  # STUDENT | ADMIN

    # Cross-border profile: where money comes from and where the student studies
    home_country: Mapped[str] = mapped_column(String(60), default="Bangladesh")
    home_currency: Mapped[str] = mapped_column(String(3), default="BDT")
    study_country: Mapped[str] = mapped_column(String(60), default="China")
    study_currency: Mapped[str] = mapped_column(String(3), default="CNY")
    university_payee_id: Mapped[int | None] = mapped_column(ForeignKey("payees.id"))
    student_id: Mapped[str | None] = mapped_column(String(40))

    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
