"""
Payment history report: a verifiable record of the student's regular payments (rent, family support, tuition),
for landlords, banks and universities in a country where the student has no credit history yet.

It is not a credit score. It lists what was due, when it was paid, and whether it was on time. Rules:
- A standing instruction (rent, money for family) creates one obligation per month, due on its day of the
  month, from the first month it was paid within the period. A payment to that payee in the same month is on
  time if made by the due day plus GRACE_DAYS, otherwise late. No payment once the grace period has passed is
  missed.
- A tuition invoice is on time if paid by its due date; an unpaid invoice past its due date is missed.
- Other outgoing transfers are listed without an on-time judgement. Card spending and conversions between the
  student's own wallets are left out.

An issued report is a snapshot with a reference and an HMAC-SHA256 verification code, like a receipt.
"""

import hashlib
import hmac
import io
import json
import re
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Payee, PaymentReport, StandingInstruction, Transaction, TuitionInvoice, User
from app.services import audit, receipts

REPORT_VERSION = 1
GRACE_DAYS = 3
SHORT_CODE_LEN = 16
FAMILY = {"mother", "father", "sibling", "parent", "brother", "sister", "family"}
MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


class HistoryError(ValueError):
    pass


def _day(dt: datetime) -> date:
    return (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).date()


def _period(today: date, months: int) -> list[tuple[int, int]]:
    """(year, month) for the last `months` calendar months including the current one, oldest first."""
    out = []
    for back in range(months - 1, -1, -1):
        y, m = divmod(today.year * 12 + today.month - 1 - back, 12)
        out.append((y, m + 1))
    return out


def _hint(account: str | None) -> str | None:
    return ("****" + account[-4:]) if account else None


def _category(payee: Payee | None, note: str | None) -> str:
    rel = (payee.relationship or "").lower() if payee else ""
    if rel == "landlord" or (note or "").lower().startswith("rent"):
        return "Rent"
    if rel in FAMILY:
        return "Family support"
    return "Regular payment"


def build(db: Session, user: User, months: int = 6, today: date | None = None) -> dict:
    if not 1 <= months <= 12:
        raise HistoryError("Choose between 1 and 12 months")
    today = today or datetime.now(timezone.utc).date()
    period = _period(today, months)
    start = date(period[0][0], period[0][1], 1)

    payments = [t for t in db.scalars(select(Transaction).where(
        Transaction.user_id == user.id, Transaction.direction == "OUT", Transaction.status == "COMPLETED",
        Transaction.kind.in_(("TUITION", "REMITTANCE_OUT"))).order_by(Transaction.executed_at)).all()
        if t.executed_at and start <= _day(t.executed_at) <= today]
    payees = {p.id: p for p in db.scalars(select(Payee).where(Payee.id.in_({t.payee_id for t in payments if t.payee_id}
                                                                         | {0}))).all()}
    used: set[int] = set()
    obligations: list[dict] = []

    def item(category, payee_name, account, amount, currency, due, tx, status):
        return {"category": category, "payee": payee_name, "account_hint": _hint(account),
                "amount": round(amount, 2), "currency": currency, "due_date": due.isoformat() if due else None,
                "paid_date": _day(tx.executed_at).isoformat() if tx else None,
                "transaction_id": tx.id if tx else None, "status": status}

    # Regular payments from standing instructions
    for si in db.scalars(select(StandingInstruction).where(StandingInstruction.user_id == user.id)).all():
        payee = db.get(Payee, si.payee_id)
        to_payee = [t for t in payments if t.payee_id == si.payee_id]
        if not to_payee or payee is None:
            continue  # nothing to judge yet
        first = _day(to_payee[0].executed_at)
        category = _category(payee, si.note)
        for y, m in period:
            due = date(y, m, min(si.day_of_month, 28))
            if due > today or (y, m) < (first.year, first.month):
                continue
            in_month = [t for t in to_payee if t.id not in used and (_day(t.executed_at).year, _day(t.executed_at).month) == (y, m)]
            if in_month:
                tx = in_month[0]
                used.add(tx.id)
                late = _day(tx.executed_at) > due + timedelta(days=GRACE_DAYS)
                obligations.append(item(category, payee.name, payee.account_ref, tx.amount, tx.currency, due, tx,
                                        "LATE" if late else "ON_TIME"))
            elif today > due + timedelta(days=GRACE_DAYS):
                obligations.append(item(category, payee.name, payee.account_ref, si.amount, si.currency, due, None,
                                        "MISSED"))

    # Tuition invoices
    upcoming = []
    for inv in db.scalars(select(TuitionInvoice).where(TuitionInvoice.user_id == user.id)).all():
        due = date.fromisoformat(inv.due_date)
        uni = db.get(Payee, inv.payee_id)
        tx = db.get(Transaction, inv.transaction_id) if inv.transaction_id else None
        if inv.status == "PAID" and tx and tx.executed_at and start <= _day(tx.executed_at) <= today:
            used.add(tx.id)
            status = "ON_TIME" if _day(tx.executed_at) <= due else "LATE"
            obligations.append(item(f"Tuition · {inv.semester}", uni.name if uni else "University",
                                    uni.account_ref if uni else None, tx.amount, tx.currency, due, tx, status))
        elif inv.status == "OPEN" and start <= due < today:
            obligations.append(item(f"Tuition · {inv.semester}", uni.name if uni else "University",
                                    uni.account_ref if uni else None, inv.amount, inv.currency, due, None, "MISSED"))
        elif inv.status == "OPEN" and due >= today:
            upcoming.append({"category": f"Tuition · {inv.semester}", "amount": inv.amount,
                             "currency": inv.currency, "due_date": inv.due_date})

    # Everything else that left the student's wallets to someone else
    others = [item("Other transfer", t.counterparty, t.counterparty_account, t.amount, t.currency, None, t, "PAID")
              for t in payments if t.id not in used]

    judged = sorted(obligations, key=lambda o: o["due_date"])
    on_time = sum(o["status"] == "ON_TIME" for o in judged)
    late = sum(o["status"] == "LATE" for o in judged)
    missed = sum(o["status"] == "MISSED" for o in judged)
    streak = 0
    for o in reversed(judged):
        if o["status"] != "ON_TIME":
            break
        streak += 1

    categories: dict[str, dict] = {}
    for o in judged:
        key = "Tuition" if o["category"].startswith("Tuition") else o["category"]
        c = categories.setdefault(key, {"name": key, "due": 0, "on_time": 0, "late": 0, "missed": 0})
        c["due"] += 1
        c[o["status"].lower()] += 1

    totals: dict[str, float] = {}
    for x in judged + others:
        if x["status"] != "MISSED":
            totals[x["currency"]] = round(totals.get(x["currency"], 0.0) + x["amount"], 2)

    uni = db.get(Payee, user.university_payee_id) if user.university_payee_id else None
    items = sorted(judged + others, key=lambda x: x["paid_date"] or x["due_date"], reverse=True)
    return {
        "version": REPORT_VERSION,
        "issued_to": user.full_name,
        "student_id": user.student_id,
        "university": uni.name if uni else None,
        "home_country": user.home_country,
        "study_country": user.study_country,
        "months": months,
        "period_start": start.isoformat(),
        "period_end": today.isoformat(),
        "summary": {
            "payments_due": len(judged), "on_time": on_time, "late": late, "missed": missed,
            "on_time_rate": round(on_time * 100 / len(judged)) if judged else None,
            "current_streak": streak, "other_transfers": len(others), "totals": totals,
            "months_with_payments": len({x["paid_date"][:7] for x in judged + others if x["paid_date"]}),
        },
        "categories": list(categories.values()),
        "items": items,
        "upcoming": upcoming,
        "rules": f"On time = paid by the due day (+{GRACE_DAYS} days grace for monthly payments; tuition by its "
                 "due date). Card spending and conversions between the student's own wallets are not included.",
    }


def _key() -> bytes:
    return hashlib.sha256(b"history:" + receipts._key()).digest()  # domain-separated from receipt codes


def _sign(fields: dict) -> str:
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"), default=str)
    return hmac.new(_key(), canonical.encode("utf-8"), hashlib.sha256).hexdigest()


def _code(fields: dict) -> str:
    short = _sign(fields)[:SHORT_CODE_LEN].upper()
    return "-".join(short[i:i + 4] for i in range(0, SHORT_CODE_LEN, 4))


def view(rep: PaymentReport) -> dict:
    f = rep.fields or {}
    code = _code(f)
    return {**f, "verification_code": code, "pdf_path": f"/api/history/reports/{rep.reference}/pdf",
            "verify_url": f"/api/history/verify?reference={rep.reference}&code={code.replace('-', '')}"}


def issue(db: Session, user: User, months: int = 6) -> PaymentReport:
    fields = build(db, user, months)
    rep = PaymentReport(user_id=user.id, months=months, fields={})
    db.add(rep)
    db.flush()
    now = datetime.now(timezone.utc)
    rep.reference = f"PH-{now:%Y%m%d}-{rep.id:06d}"
    rep.fields = {**fields, "reference": rep.reference, "issued_at": now.isoformat(timespec="seconds")}
    audit.record(db, user_id=user.id, actor="STUDENT", event="HISTORY_REPORT_ISSUED", tier="T0",
                 details={"reference": rep.reference, "months": months,
                          "on_time_rate": fields["summary"]["on_time_rate"]})
    return rep


def find(db: Session, reference: str) -> PaymentReport | None:
    ref = (reference or "").strip().upper()
    if not re.fullmatch(r"PH-\d{8}-\d{6,}", ref):
        return None
    return db.scalar(select(PaymentReport).where(PaymentReport.reference == ref))


def verify(db: Session, reference: str, code: str) -> dict:
    """Public check. Returns the summary only (no payees or line items) when reference and code match."""
    rep = find(db, reference)
    given = re.sub(r"[^0-9A-Fa-f]", "", code or "").lower()
    if rep is None or len(given) < 12 or not hmac.compare_digest(_sign(rep.fields)[:len(given)], given):
        return {"valid": False, "message": "No matching report. It may be fake or altered."}
    f = rep.fields
    return {"valid": True, "message": "Genuine MoneyMate payment history report.",
            "report": {k: f[k] for k in ("reference", "issued_to", "university", "period_start", "period_end",
                                         "issued_at")}
            | {"summary": {k: f["summary"][k] for k in ("payments_due", "on_time", "late", "missed", "on_time_rate")},
               "categories": f["categories"]}}


def _date(iso: str | None) -> str:
    if not iso:
        return "-"
    d = date.fromisoformat(iso[:10])
    return f"{d.day} {MONTH_NAMES[d.month - 1]} {d.year}"


def pdf(rep: PaymentReport) -> bytes:
    from reportlab.graphics import renderPDF
    from reportlab.graphics.barcode.qr import QrCodeWidget
    from reportlab.graphics.shapes import Drawing
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm
    from reportlab.lib.utils import simpleSplit
    from reportlab.pdfgen import canvas

    r = view(rep)
    s = r["summary"]
    ink, muted, line = colors.HexColor("#111111"), colors.HexColor("#5c5c5c"), colors.HexColor("#e2e2e2")
    green, amber, red = colors.HexColor("#1e6b41"), colors.HexColor("#8a5300"), colors.HexColor("#a8231a")
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    w, h = A4
    left, right = 18 * mm, w - 18 * mm

    def header(page: int):
        c.setFillColor(ink)
        c.rect(0, h - 30 * mm, w, 30 * mm, fill=1, stroke=0)
        c.setFillColor(colors.white)
        c.setFont("Helvetica-Bold", 18)
        c.drawString(left, h - 16 * mm, "MoneyMate")
        c.setFont("Helvetica", 10)
        c.drawString(left, h - 23 * mm, "Payment history report")
        c.drawRightString(right, h - 16 * mm, r["reference"])
        c.drawRightString(right, h - 23 * mm, f"Page {page}")
        c.setFont("Helvetica", 7.5)
        c.setFillColor(muted)
        c.drawString(left, 10 * mm, "Sandbox demonstration: payments made through MoneyMate. This is a payment record, "
                                    "not a credit score.")

    header(1)
    y = h - 44 * mm
    c.setFillColor(ink)
    c.setFont("Helvetica-Bold", 15)
    c.drawString(left, y, r["issued_to"])
    c.setFont("Helvetica", 9.5)
    c.setFillColor(muted)
    sub = [x for x in (r.get("university"), f"Student ID {r['student_id']}" if r.get("student_id") else None) if x]
    c.drawString(left, y - 6 * mm, " · ".join(sub))
    c.drawString(left, y - 11 * mm, f"Period {_date(r['period_start'])} to {_date(r['period_end'])} · "
                                    f"issued {_date(r['issued_at'])}")

    # Summary boxes
    y -= 22 * mm
    boxes = [("On time", f"{s['on_time_rate']}%" if s["on_time_rate"] is not None else "-"),
             ("Payments due", str(s["payments_due"])), ("Paid on time", str(s["on_time"])),
             ("Late", str(s["late"])), ("Missed", str(s["missed"]))]
    bw = (right - left - 4 * 4 * mm) / 5
    for i, (label, value) in enumerate(boxes):
        x = left + i * (bw + 4 * mm)
        c.setFillColor(ink if i == 0 else colors.HexColor("#f4f4f4"))
        c.roundRect(x, y - 18 * mm, bw, 20 * mm, 3 * mm, fill=1, stroke=0)
        c.setFillColor(colors.white if i == 0 else ink)
        c.setFont("Helvetica-Bold", 16)
        c.drawString(x + 4 * mm, y - 9 * mm, value)
        c.setFont("Helvetica", 8)
        c.setFillColor(colors.HexColor("#d0d0d0") if i == 0 else muted)
        c.drawString(x + 4 * mm, y - 15 * mm, label)

    # Categories
    y -= 30 * mm
    c.setFillColor(ink)
    c.setFont("Helvetica-Bold", 11)
    c.drawString(left, y, "By type")
    y -= 6 * mm
    for cat in r["categories"]:
        c.setFont("Helvetica", 9.5)
        c.setFillColor(ink)
        c.drawString(left, y, cat["name"])
        c.setFillColor(muted)
        c.drawRightString(right, y, f"{cat['on_time']} of {cat['due']} on time"
                                    + (f" · {cat['late']} late" if cat["late"] else "")
                                    + (f" · {cat['missed']} missed" if cat["missed"] else ""))
        c.setStrokeColor(line)
        c.line(left, y - 2.5 * mm, right, y - 2.5 * mm)
        y -= 7 * mm

    # Payments table
    y -= 5 * mm
    cols = [left, left + 26 * mm, left + 74 * mm, left + 124 * mm, right]

    def table_head(yy):
        c.setFillColor(ink)
        c.rect(left, yy - 2 * mm, right - left, 7 * mm, fill=1, stroke=0)
        c.setFillColor(colors.white)
        c.setFont("Helvetica-Bold", 8.5)
        for x, t in zip(cols, ["Date", "Type", "Paid to", "Amount"]):
            c.drawString(x + 2 * mm, yy, t)
        c.drawRightString(right - 2 * mm, yy, "Status")
        return yy - 8 * mm

    c.setFillColor(ink)
    c.setFont("Helvetica-Bold", 11)
    c.drawString(left, y, "Payments")
    y = table_head(y - 7 * mm)
    page = 1
    labels = {"ON_TIME": ("On time", green), "LATE": ("Late", amber), "MISSED": ("Missed", red), "PAID": ("Paid", muted)}
    for it in r["items"]:
        if y < 62 * mm:
            c.showPage()
            page += 1
            header(page)
            y = table_head(h - 42 * mm)
        c.setFont("Helvetica", 8.5)
        c.setFillColor(ink)
        c.drawString(cols[0] + 2 * mm, y, _date(it["paid_date"] or it["due_date"]))
        c.drawString(cols[1] + 2 * mm, y, it["category"][:28])
        payee = re.sub(r"\s*\(.*\)$", "", it["payee"] or "")[:24]
        c.drawString(cols[2] + 2 * mm, y, f"{payee} {it['account_hint'] or ''}".strip())
        c.drawString(cols[3] + 2 * mm, y, f"{it['amount']:,.2f} {it['currency']}")
        text, color = labels[it["status"]]
        c.setFillColor(color)
        c.setFont("Helvetica-Bold", 8.5)
        c.drawRightString(right - 2 * mm, y, text)
        c.setStrokeColor(line)
        c.line(left, y - 2.5 * mm, right, y - 2.5 * mm)
        y -= 6.5 * mm

    # Verification box with QR code, always at the foot of the last page (rows stop above it)
    link = f"{settings.PUBLIC_BASE_URL}{r['verify_url']}"
    box_top = 52 * mm
    c.setStrokeColor(ink)
    c.roundRect(left, box_top - 36 * mm, right - left, 36 * mm, 4 * mm, stroke=1, fill=0)
    qr = QrCodeWidget(link)
    b = qr.getBounds()
    size = 28 * mm
    d = Drawing(size, size, transform=[size / (b[2] - b[0]), 0, 0, size / (b[3] - b[1]), 0, 0])
    d.add(qr)
    renderPDF.draw(d, c, right - size - 4 * mm, box_top - 32 * mm)
    c.setFillColor(ink)
    c.setFont("Helvetica-Bold", 12)
    c.drawString(left + 5 * mm, box_top - 9 * mm, f"Verification code: {r['verification_code']}")
    c.setFont("Helvetica", 8.5)
    c.setFillColor(muted)
    c.drawString(left + 5 * mm, box_top - 16 * mm, "Scan the code or open the link to check this report is genuine and unchanged:")
    c.drawString(left + 5 * mm, box_top - 21 * mm, link[:95])
    for i, part in enumerate(simpleSplit(r["rules"], "Helvetica", 8.5, right - left - 45 * mm)[:2]):
        c.drawString(left + 5 * mm, box_top - (27 + i * 4.5) * mm, part)
    c.showPage()
    c.save()
    return buf.getvalue()
