"""
Payment proof. Every completed transaction gets a receipt with a reference number and a verification
code: an HMAC-SHA256 over the receipt's fields. A landlord, university or visa office can check the
code with the public verify endpoint; changing any field (amount, payee, date) makes the code invalid.
"""

import hashlib
import hmac
import io
import json
import re
from datetime import timezone

from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Payee, Transaction, User

RECEIPT_VERSION = 1
SHORT_CODE_LEN = 16  # hex characters shown on the receipt (64 bits)
KIND_TITLE = {"TUITION": "Tuition payment", "REMITTANCE_OUT": "International transfer", "REMITTANCE_IN": "Money received",
              "CARD": "Card payment", "FX": "Currency exchange"}


class ReceiptError(ValueError):
    pass


def _key() -> bytes:
    secret = settings.RECEIPT_SIGNING_KEY or f"receipt:{settings.JWT_SECRET_KEY}"
    return hashlib.sha256(secret.encode("utf-8")).digest()


def reference(tx: Transaction) -> str:
    return f"MM-{tx.executed_at:%Y%m%d}-{tx.id:06d}"


def _id_from_reference(ref: str) -> int | None:
    m = re.fullmatch(r"MM-\d{8}-(\d{6,})", (ref or "").strip().upper())
    return int(m.group(1)) if m else None


def _fields(db: Session, tx: Transaction, user: User) -> dict:
    payee = db.get(Payee, tx.payee_id) if tx.payee_id else None
    executed = tx.executed_at if tx.executed_at.tzinfo else tx.executed_at.replace(tzinfo=timezone.utc)
    return {
        "version": RECEIPT_VERSION,
        "reference": reference(tx),
        "transaction_id": tx.id,
        "issued_to": user.full_name,
        "student_id": user.student_id,
        "type": KIND_TITLE.get(tx.kind, tx.kind),
        "direction": tx.direction,
        "amount": round(tx.amount, 2),
        "currency": tx.currency,
        "counterparty": tx.counterparty,
        "counterparty_account": ("****" + tx.counterparty_account[-4:]) if tx.counterparty_account else None,
        "payee_verified_institution": bool(payee and payee.verified and payee.owner_user_id is None),
        "provider": tx.provider,
        "fee": round(tx.fee or 0.0, 2),
        "fx_rate": tx.fx_rate,
        "memo": tx.memo,
        "executed_at": executed.isoformat(timespec="seconds"),
        "approval": "Conversion between the student's own wallets" if tx.kind == "FX" else
                    {"T2": "Verified by the student on their phone", "T1": "Confirmed by the student",
                     "T0": "Incoming transfer"}.get(tx.tier or "", tx.tier),
    }


def _sign(fields: dict) -> str:
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"), default=str)
    return hmac.new(_key(), canonical.encode("utf-8"), hashlib.sha256).hexdigest()


def build(db: Session, tx: Transaction) -> dict:
    if tx.status != "COMPLETED" or tx.executed_at is None:
        raise ReceiptError("Receipts are only issued for completed transactions")
    user = db.get(User, tx.user_id)
    fields = _fields(db, tx, user)
    code = _sign(fields)
    short = code[:SHORT_CODE_LEN].upper()
    return {**fields, "verification_code": "-".join(short[i:i + 4] for i in range(0, SHORT_CODE_LEN, 4)),
            "verify_url": f"/api/receipts/verify?reference={fields['reference']}&code={short}"}


def verify(db: Session, ref: str, code: str) -> dict:
    """Public check: does this reference + code match a real, unchanged receipt?"""
    tx_id = _id_from_reference(ref)
    given = re.sub(r"[^0-9A-Fa-f]", "", code or "").lower()
    tx = db.get(Transaction, tx_id) if tx_id else None
    if tx is None or tx.status != "COMPLETED" or tx.executed_at is None or len(given) < SHORT_CODE_LEN \
            or reference(tx) != (ref or "").strip().upper():
        return {"valid": False, "message": "No matching receipt. It may be fake or altered."}
    expected = _sign(_fields(db, tx, db.get(User, tx.user_id)))
    if not hmac.compare_digest(expected[:len(given)], given):
        return {"valid": False, "message": "No matching receipt. It may be fake or altered."}
    r = build(db, tx)
    return {"valid": True, "message": "Genuine MoneyMate receipt.",
            "receipt": {k: r[k] for k in ("reference", "issued_to", "type", "amount", "currency", "counterparty",
                                          "payee_verified_institution", "executed_at")}}


def pdf(db: Session, tx: Transaction) -> bytes:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas

    r = build(db, tx)
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    w, h = A4
    teal = colors.HexColor("#0f766e")

    c.setFillColor(teal)
    c.rect(0, h - 32 * mm, w, 32 * mm, fill=1, stroke=0)
    c.setFillColor(colors.white)
    c.setFont("Helvetica-Bold", 20)
    c.drawString(20 * mm, h - 18 * mm, "MoneyMate")
    c.setFont("Helvetica", 10)
    c.drawString(20 * mm, h - 25 * mm, "Payment receipt (sandbox)")
    c.drawRightString(w - 20 * mm, h - 18 * mm, r["reference"])

    c.setFillColor(colors.black)
    y = h - 48 * mm
    c.setFont("Helvetica-Bold", 16)
    sign = "-" if r["direction"] == "OUT" else "+"
    c.drawString(20 * mm, y, f"{r['type']}: {sign}{r['amount']:,.2f} {r['currency']}")
    y -= 12 * mm

    rows = [
        ("Issued to", f"{r['issued_to']}" + (f"  (student ID {r['student_id']})" if r["student_id"] else "")),
        ("Paid to" if r["direction"] == "OUT" else "Received from", r["counterparty"]),
        ("Account", r["counterparty_account"] or "-"),
        ("Verified institution", "Yes, official account in registry" if r["payee_verified_institution"] else "No"),
        ("Date and time (UTC)", r["executed_at"].replace("T", " ").replace("+00:00", "")),
        ("Provider", r["provider"] or "-"),
        ("Fee", f"{r['fee']:,.2f} {r['currency']}"),
        ("Exchange rate", str(r["fx_rate"]) if r["fx_rate"] else "-"),
        ("Note", r["memo"] or "-"),
        ("Approval", r["approval"] or "-"),
    ]
    c.setFont("Helvetica", 11)
    for label, value in rows:
        c.setFillColor(colors.HexColor("#64748b"))
        c.drawString(20 * mm, y, label)
        c.setFillColor(colors.black)
        c.drawString(70 * mm, y, str(value)[:80])
        y -= 8 * mm

    y -= 6 * mm
    c.setStrokeColor(teal)
    c.roundRect(20 * mm, y - 22 * mm, w - 40 * mm, 28 * mm, 4 * mm, stroke=1, fill=0)
    c.setFont("Helvetica-Bold", 12)
    c.drawString(26 * mm, y - 2 * mm, f"Verification code: {r['verification_code']}")
    c.setFont("Helvetica", 9)
    c.drawString(26 * mm, y - 9 * mm, "Anyone can check this receipt is genuine and unchanged at:")
    c.drawString(26 * mm, y - 15 * mm, f"{settings.PUBLIC_BASE_URL}{r['verify_url']}")

    c.setFont("Helvetica", 8)
    c.setFillColor(colors.HexColor("#94a3b8"))
    c.drawString(20 * mm, 15 * mm, "Sandbox receipt for demonstration. No real money was moved.")
    c.showPage()
    c.save()
    return buf.getvalue()
