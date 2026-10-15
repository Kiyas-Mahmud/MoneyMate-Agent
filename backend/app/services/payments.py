"""
Money-moving operations. Every payment goes through the same pipeline:

  build behavioural features -> hybrid risk score -> permission tier -> execute / wait / block
  -> transaction + agent action + hash-chained audit entry

Used by the agent tools and by the REST API, so the UI and the agent follow identical rules.
"""

from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import AgentAction, Payee, Transaction, TuitionInvoice, User
from app.services import audit, sandbox, verification
from app.services.policy import decide_payment
from app.services.risk import engine


class PaymentError(ValueError):
    pass


def _now():
    return datetime.now(timezone.utc)


def _auto_used_today(db: Session, user_id: int) -> float:
    return db.scalar(select(func.coalesce(func.sum(Transaction.amount_usd), 0.0)).where(
        Transaction.user_id == user_id, Transaction.tier == "T1", Transaction.status == "COMPLETED",
        Transaction.created_at >= _now() - timedelta(hours=24))) or 0.0


def tx_view(tx: Transaction) -> dict:
    return {
        "id": tx.id, "kind": tx.kind, "direction": tx.direction, "amount": round(tx.amount, 2),
        "currency": tx.currency, "amount_usd": round(tx.amount_usd, 2), "counterparty": tx.counterparty,
        "counterparty_account": ("****" + tx.counterparty_account[-4:]) if tx.counterparty_account else None,
        "channel": tx.channel, "provider": tx.provider, "fee": tx.fee, "fx_rate": tx.fx_rate, "memo": tx.memo,
        "status": tx.status, "risk_score": tx.risk_score, "risk_level": tx.risk_level,
        "risk_reasons": tx.risk_reasons, "model_scores": tx.model_scores, "tier": tx.tier,
        "initiated_by": tx.initiated_by,
        "created_at": tx.created_at.isoformat() if tx.created_at else None,
        "executed_at": tx.executed_at.isoformat() if tx.executed_at else None,
    }


def action_view(a: AgentAction) -> dict:
    return {"id": a.id, "tool": a.tool, "tier": a.tier, "status": a.status, "summary": a.summary,
            "transaction_id": a.transaction_id, "result": a.result,
            "expires_at": a.expires_at.isoformat() if a.expires_at else None,
            "created_at": a.created_at.isoformat() if a.created_at else None}


def _finalize(db: Session, user: User, *, session_id: str, tool: str, args: dict, tx: Transaction,
              risk: dict, decision, summary: str, extra: dict) -> dict:
    tx.risk_score, tx.risk_level = risk["score"], risk["level"]
    tx.risk_reasons = [r["text"] for r in risk["reasons"]]
    tx.model_scores, tx.tier = risk["model_scores"], decision.tier
    db.add(tx)
    db.flush()

    action = AgentAction(user_id=user.id, session_id=session_id, tool=tool, args=args, tier=decision.tier,
                         summary=summary, transaction_id=tx.id)
    if decision.decision == "BLOCK":
        tx.status = action.status = "BLOCKED"
    elif decision.decision == "CONFIRM":
        tx.status = action.status = "AWAITING_CONFIRMATION"
        action.expires_at = _now() + timedelta(minutes=settings.CONFIRMATION_TTL_MINUTES)
    else:
        sandbox.settle(db, tx)
        action.status = "AUTO_EXECUTED"
        action.decided_at = _now()

    result = {"status": action.status, "summary": summary, "policy": decision.as_dict(),
              "risk": {k: risk[k] for k in ("score", "level", "reasons", "protective_factors", "model_scores")},
              "transaction": tx_view(tx), **extra}
    action.result = result
    db.add(action)
    db.flush()
    result["action_id"] = action.id
    action.result = dict(result)

    audit.record(db, user_id=user.id, actor="AGENT" if tx.initiated_by == "AGENT" else "STUDENT",
                 event=f"PAYMENT_{action.status}", tier=decision.tier,
                 details={"action_id": action.id, "transaction_id": tx.id, "kind": tx.kind,
                          "amount": tx.amount, "currency": tx.currency, "counterparty": tx.counterparty,
                          "risk_score": risk["score"], "risk_level": risk["level"], "rules": decision.rules})
    return result


def _check_funds(db: Session, user: User, currency: str, amount: float):
    w = sandbox.get_wallet(db, user.id, currency)
    if w is None or w.balance + 1e-9 < amount:
        have = w.balance if w else 0.0
        raise PaymentError(f"Insufficient {currency} balance: need {amount:,.2f}, have {have:,.2f}. "
                           f"Convert money into {currency} first.")


def pay_tuition(db: Session, user: User, *, session_id: str, initiated_by: str, amount: float | None = None,
                currency: str | None = None, payee_name: str | None = None, account_ref: str | None = None,
                request_text: str | None = None, semester: str | None = None) -> dict:
    analysis, pressure = None, 0
    if request_text:
        analysis = verification.analyze_request(db, request_text)
        ext = analysis["extracted"]
        amount = amount or ext["amount"]
        currency = currency or ext["currency"]
        payee_name = payee_name or ext["payee"]
        account_ref = account_ref or ext["account"]
        pressure = analysis["pressure_flags"]

    invoice = None
    if not payee_name and not account_ref:
        if not user.university_payee_id:
            raise PaymentError("Which institution should receive the tuition?")
        uni = db.get(Payee, user.university_payee_id)
        payee_name, account_ref = uni.name, uni.account_ref
        invoice = db.scalar(select(TuitionInvoice).where(
            TuitionInvoice.user_id == user.id, TuitionInvoice.payee_id == uni.id, TuitionInvoice.status == "OPEN")
            .order_by(TuitionInvoice.due_date))
        if invoice and not amount:
            amount, currency, semester = invoice.amount, invoice.currency, semester or invoice.semester

    ver = verification.verify_payee(db, payee_name, account_ref)
    payee = db.get(Payee, ver["payee_id"]) if ver["status"] == "VERIFIED" else None
    currency = sandbox.check_currency(currency or (payee.currency if payee else user.study_currency))
    if not amount or amount <= 0:
        raise PaymentError("What is the tuition amount on the invoice?")

    amount_usd = sandbox.to_usd(amount, currency)
    features = engine.build_features(db, user, kind="TUITION", amount_usd=amount_usd, payee=payee,
                                     counterparty_account=account_ref, pressure_flags=pressure,
                                     name_account_mismatch=ver["status"] == "IMPERSONATION")
    risk = engine.score(features)
    decision = decide_payment(kind="TUITION", risk=risk, features=features, verification_status=ver["status"],
                              amount_usd=amount_usd, auto_used_today_usd=_auto_used_today(db, user.id))
    if decision.decision != "BLOCK":
        _check_funds(db, user, currency, amount)

    name = payee.name if payee else (payee_name or "Unknown payee")
    tx = Transaction(user_id=user.id, kind="TUITION", direction="OUT", amount=amount, currency=currency,
                     amount_usd=amount_usd, payee_id=payee.id if payee else None, counterparty=name,
                     counterparty_account=payee.account_ref if payee else account_ref, channel="BANK_TRANSFER",
                     memo=f"Tuition{(' - ' + semester) if semester else ''}", features=features,
                     initiated_by=initiated_by, status="PENDING")
    summary = f"Pay {amount:,.2f} {currency} tuition to {name}"
    args = {"amount": amount, "currency": currency, "payee_name": payee_name, "account_ref": account_ref,
            "semester": semester, "from_request_text": bool(request_text),
            "invoice_id": invoice.id if invoice else None}
    result = _finalize(db, user, session_id=session_id, tool="pay_tuition", args=args, tx=tx, risk=risk,
                       decision=decision, summary=summary,
                       extra={"payee_verification": ver, "request_analysis": analysis,
                              "invoice": {"semester": invoice.semester, "due_date": invoice.due_date}
                              if invoice else None})
    if invoice and tx.status == "COMPLETED":
        invoice.status, invoice.transaction_id = "PAID", tx.id
    return result


def _settle_invoice(db: Session, a: AgentAction, tx: Transaction):
    inv_id = (a.args or {}).get("invoice_id")
    if inv_id:
        inv = db.get(TuitionInvoice, inv_id)
        if inv and inv.status == "OPEN":
            inv.status, inv.transaction_id = "PAID", tx.id


def send_remittance(db: Session, user: User, *, session_id: str, initiated_by: str, recipient: str,
                    amount: float, currency: str | None = None, provider_id: str | None = None,
                    account_ref: str | None = None, country: str | None = None,
                    receive_currency: str | None = None, channel: str = "BANK_TRANSFER",
                    request_text: str | None = None) -> dict:
    pressure = verification.analyze_request(db, request_text)["pressure_flags"] if request_text else 0
    payee = verification.find_user_payee(db, user.id, recipient)
    if payee is None:
        if not account_ref or not country:
            raise PaymentError(f"'{recipient}' is not one of your saved recipients. "
                               "Give their account number and country to add them.")
        payee = Payee(owner_user_id=user.id, name=recipient, kind="INDIVIDUAL", country=country,
                      currency=receive_currency or ("BDT" if country == user.home_country else "USD"),
                      account_ref=account_ref, verified=False)
        db.add(payee)
        db.flush()

    src = sandbox.check_currency(currency or user.study_currency)
    dst = sandbox.check_currency(receive_currency or payee.currency)
    options = sandbox.compare(amount, src, dst)
    chosen = next((q for q in options if q["provider_id"] == provider_id), options[0])

    amount_usd = sandbox.to_usd(amount, src)
    features = engine.build_features(db, user, kind="REMITTANCE_OUT", amount_usd=amount_usd, payee=payee,
                                     channel=channel, pressure_flags=pressure)
    risk = engine.score(features)
    decision = decide_payment(kind="REMITTANCE_OUT", risk=risk, features=features, verification_status=None,
                              amount_usd=amount_usd, auto_used_today_usd=_auto_used_today(db, user.id))
    if decision.decision != "BLOCK":
        _check_funds(db, user, src, amount)

    tx = Transaction(user_id=user.id, kind="REMITTANCE_OUT", direction="OUT", amount=amount, currency=src,
                     amount_usd=amount_usd, payee_id=payee.id, counterparty=payee.name,
                     counterparty_account=payee.account_ref, channel=channel, provider=chosen["provider"],
                     fee=chosen["fee"], fx_rate=chosen["rate"],
                     memo=f"Recipient gets {chosen['receive_amount']:,.2f} {dst}", features=features,
                     initiated_by=initiated_by, status="PENDING")
    summary = (f"Send {amount:,.2f} {src} to {payee.name} via {chosen['provider']} "
               f"(they receive {chosen['receive_amount']:,.2f} {dst})")
    args = {"recipient": recipient, "amount": amount, "currency": src, "receive_currency": dst,
            "provider_id": chosen["provider_id"], "channel": channel}
    return _finalize(db, user, session_id=session_id, tool="send_remittance", args=args, tx=tx, risk=risk,
                     decision=decision, summary=summary,
                     extra={"quote": chosen, "alternatives": options[1:3]})


def convert_currency(db: Session, user: User, *, session_id: str, initiated_by: str, amount: float,
                     from_currency: str, to_currency: str) -> dict:
    """Move money between the student's own wallets (no third party, so no fraud score)."""
    src, dst = sandbox.check_currency(from_currency), sandbox.check_currency(to_currency)
    q = sandbox.quote(amount, src, dst, "remitlite")
    _check_funds(db, user, src, amount)
    sandbox.debit(db, user.id, src, amount)
    sandbox.credit(db, user.id, dst, q["receive_amount"])
    tx = Transaction(user_id=user.id, kind="FX", direction="OUT", amount=amount, currency=src,
                     amount_usd=sandbox.to_usd(amount, src), counterparty=f"Own {dst} wallet", channel="INTERNAL",
                     provider=q["provider"], fee=q["fee"], fx_rate=q["rate"],
                     memo=f"Converted to {q['receive_amount']:,.2f} {dst}", initiated_by=initiated_by,
                     status="COMPLETED", tier="T1", executed_at=_now())
    db.add(tx)
    db.flush()
    action = AgentAction(user_id=user.id, session_id=session_id, tool="convert_currency",
                         args={"amount": amount, "from": src, "to": dst}, tier="T1", status="AUTO_EXECUTED",
                         summary=f"Convert {amount:,.2f} {src} to {q['receive_amount']:,.2f} {dst}",
                         transaction_id=tx.id, decided_at=_now())
    db.add(action)
    db.flush()
    action.result = {"status": "AUTO_EXECUTED", "summary": action.summary, "quote": q, "action_id": action.id,
                     "transaction": tx_view(tx)}
    audit.record(db, user_id=user.id, actor="AGENT" if initiated_by == "AGENT" else "STUDENT",
                 event="FX_CONVERTED", tier="T1", details={"action_id": action.id, "amount": amount, "from": src,
                                                          "to": dst, "received": q["receive_amount"]})
    return action.result


def receive_transfer(db: Session, user: User, *, sender: str, amount: float, currency: str, note: str = "") -> dict:
    """Sandbox only: simulate money arriving (family support, salary, or a stranger's transfer)."""
    currency = sandbox.check_currency(currency)
    tx = Transaction(user_id=user.id, kind="REMITTANCE_IN", direction="IN", amount=amount, currency=currency,
                     amount_usd=sandbox.to_usd(amount, currency), counterparty=sender, channel="BANK_TRANSFER",
                     memo=note or None, initiated_by="SANDBOX", status="PENDING", tier="T0")
    db.add(tx)
    db.flush()
    sandbox.settle(db, tx)
    audit.record(db, user_id=user.id, actor="SYSTEM", event="TRANSFER_RECEIVED", tier="T0",
                 details={"transaction_id": tx.id, "sender": sender, "amount": amount, "currency": currency})
    return tx_view(tx)


def confirm_action(db: Session, user: User, action_id: int) -> dict:
    a = db.get(AgentAction, action_id)
    if a is None or a.user_id != user.id:
        raise PaymentError("Action not found")
    if a.status != "AWAITING_CONFIRMATION":
        raise PaymentError(f"Action is {a.status}, it cannot be confirmed")
    tx = db.get(Transaction, a.transaction_id)
    expires = a.expires_at if a.expires_at.tzinfo else a.expires_at.replace(tzinfo=timezone.utc)
    if expires < _now():
        a.status, tx.status = "EXPIRED", "EXPIRED"
        audit.record(db, user_id=user.id, actor="SYSTEM", event="PAYMENT_EXPIRED", tier=a.tier,
                     details={"action_id": a.id, "transaction_id": tx.id})
        db.commit()
        raise PaymentError("This confirmation expired. Ask the agent again.")
    sandbox.settle(db, tx)  # re-checks the balance at execution time
    _settle_invoice(db, a, tx)
    a.status, a.decided_at = "CONFIRMED", _now()
    a.result = {**(a.result or {}), "status": "CONFIRMED", "transaction": tx_view(tx)}
    audit.record(db, user_id=user.id, actor="STUDENT", event="PAYMENT_CONFIRMED", tier=a.tier,
                 details={"action_id": a.id, "transaction_id": tx.id, "amount": tx.amount, "currency": tx.currency,
                          "counterparty": tx.counterparty})
    return action_view(a)


def reject_action(db: Session, user: User, action_id: int) -> dict:
    a = db.get(AgentAction, action_id)
    if a is None or a.user_id != user.id:
        raise PaymentError("Action not found")
    if a.status != "AWAITING_CONFIRMATION":
        raise PaymentError(f"Action is {a.status}, it cannot be rejected")
    tx = db.get(Transaction, a.transaction_id)
    a.status, tx.status, a.decided_at = "REJECTED", "REJECTED", _now()
    a.result = {**(a.result or {}), "status": "REJECTED", "transaction": tx_view(tx)}
    audit.record(db, user_id=user.id, actor="STUDENT", event="PAYMENT_REJECTED", tier=a.tier,
                 details={"action_id": a.id, "transaction_id": tx.id})
    return action_view(a)


def credit_passport(db: Session, user: User) -> dict:
    """Verified payment history the student can share with landlords or banks (preview)."""
    txs = db.scalars(select(Transaction).where(Transaction.user_id == user.id, Transaction.status == "COMPLETED",
                                               Transaction.direction == "OUT")
                     .order_by(Transaction.created_at)).all()
    if not txs:
        return {"months_of_history": 0, "on_time_payments": 0, "score": None}
    first = txs[0].created_at
    months = max(1, round((_now() - (first if first.tzinfo else first.replace(tzinfo=timezone.utc))).days / 30))
    tuition = [t for t in txs if t.kind == "TUITION"]
    remits = [t for t in txs if t.kind == "REMITTANCE_OUT"]
    blocked = db.scalar(select(func.count()).select_from(Transaction).where(
        Transaction.user_id == user.id, Transaction.status == "BLOCKED")) or 0
    # Transparent 300-850 style indicator: history length, payment count, tuition record. Not a bureau score.
    raw = 300 + min(months, 24) * 10 + min(len(txs), 60) * 3 + min(len(tuition), 4) * 25 + min(len(remits), 12) * 5
    return {
        "holder": user.full_name, "home_country": user.home_country, "study_country": user.study_country,
        "months_of_history": months, "on_time_payments": len(txs), "tuition_payments": len(tuition),
        "tuition_total_usd": round(sum(t.amount_usd for t in tuition), 2),
        "remittances_sent": len(remits), "blocked_fraud_attempts": blocked,
        "reliability_score": min(raw, 850),
        "note": "Preview: verified payment history from MoneyMate, not a credit bureau score.",
    }
