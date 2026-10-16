"""
Money-moving operations. Every payment goes through the same pipeline:

  build behavioural features -> hybrid risk score -> policy (verify or block)
  -> prepared transaction + agent action + "verify to complete" notification + audit entry
  -> the student verifies on their phone -> money moves -> receipt

The agent never moves money on its own: there is no auto-execute path. Used by the agent tools, the
daily monitor (standing instructions) and the REST API, so all of them follow identical rules.
"""

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import AgentAction, Payee, Transaction, TuitionInvoice, User
from app.services import audit, devices, receipts, reminders, sandbox, verification
from app.services.notify import notify
from app.services.policy import decide_conversion, decide_payment
from app.services.risk import engine

MULE_ALERT_MIN_USD = 300.0


class PaymentError(ValueError):
    pass


def _iso(dt: datetime | None) -> str | None:
    """ISO time with an explicit UTC offset (SQLite hands datetimes back without their timezone)."""
    return None if dt is None else (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).isoformat()


def _now():
    return datetime.now(timezone.utc)


def _aware(dt: datetime) -> datetime:
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


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
            "needs_verification": a.status == "AWAITING_VERIFICATION",
            "expires_at": _iso(a.expires_at),
            "created_at": a.created_at.isoformat() if a.created_at else None}


def _ttl(initiated_by: str) -> timedelta:
    if initiated_by == "SCHEDULE":
        return timedelta(hours=settings.SCHEDULED_TTL_HOURS)
    return timedelta(minutes=settings.CONFIRMATION_TTL_MINUTES)


def _await_verification(db: Session, user: User, action: AgentAction, txs: list[Transaction], initiated_by: str):
    """Park the payment and ask the student to verify it on their phone."""
    for t in txs:
        t.status = "AWAITING_VERIFICATION"
    action.status = "AWAITING_VERIFICATION"
    action.verification_nonce = devices.new_nonce()
    action.expires_at = _now() + _ttl(initiated_by)
    db.flush()
    prefix = "Scheduled payment ready. " if initiated_by == "SCHEDULE" else ""
    notify(db, user.id, kind="VERIFY_PAYMENT", title="Verify to complete your payment",
           body=f"{prefix}{action.summary}. Please complete verification to complete the payment.",
           action_id=action.id, data={"expires_at": _iso(action.expires_at)})


def _finalize(db: Session, user: User, *, session_id: str, tool: str, args: dict, tx: Transaction,
              risk: dict, decision, summary: str, extra: dict, extra_txs: list[Transaction] | None = None) -> dict:
    tx.risk_score, tx.risk_level = risk["score"], risk["level"]
    tx.risk_reasons = [r["text"] for r in risk["reasons"]]
    tx.model_scores, tx.tier = risk["model_scores"], decision.tier
    db.add(tx)
    db.flush()

    action = AgentAction(user_id=user.id, session_id=session_id, tool=tool, args=args, tier=decision.tier,
                         summary=summary, transaction_id=tx.id, status="PENDING")
    db.add(action)
    db.flush()
    if decision.decision == "BLOCK":
        tx.status = action.status = "BLOCKED"
        for t in extra_txs or []:
            t.status = "CANCELLED"
        notify(db, user.id, kind="PAYMENT_BLOCKED", title="Payment blocked",
               body=f"{summary}. {decision.rules[0]}.", action_id=action.id)
    else:
        _await_verification(db, user, action, [tx, *(extra_txs or [])], tx.initiated_by)

    result = {"status": action.status, "summary": summary, "policy": decision.as_dict(),
              "risk": {k: risk[k] for k in ("score", "level", "reasons", "protective_factors", "model_scores")},
              "transaction": tx_view(tx), "action_id": action.id,
              "expires_at": _iso(action.expires_at), **extra}
    action.result = dict(result)

    audit.record(db, user_id=user.id, actor="AGENT" if tx.initiated_by in ("AGENT", "SCHEDULE") else "STUDENT",
                 event=f"PAYMENT_{action.status}", tier=decision.tier,
                 details={"action_id": action.id, "transaction_id": tx.id, "kind": tx.kind,
                          "amount": tx.amount, "currency": tx.currency, "counterparty": tx.counterparty,
                          "risk_score": risk["score"], "risk_level": risk["level"], "rules": decision.rules,
                          "initiated_by": tx.initiated_by})
    return result


def _balance(db: Session, user: User, currency: str) -> float:
    w = sandbox.get_wallet(db, user.id, currency)
    return w.balance if w else 0.0


def _check_funds(db: Session, user: User, currency: str, amount: float):
    have = _balance(db, user, currency)
    if have + 1e-9 < amount:
        raise PaymentError(f"Insufficient {currency} balance: need {amount:,.2f}, have {have:,.2f}. "
                           f"Convert money into {currency} first.")


def _plan_conversion(db: Session, user: User, currency: str, shortfall: float, initiated_by: str) -> tuple[dict, Transaction]:
    """Prepare (not execute) the conversion that covers a shortfall; it runs only when the student verifies."""
    src = user.home_currency if user.home_currency != currency else "USD"
    cost = round(reminders._cost_to_cover(shortfall, src, currency), 2)
    if _balance(db, user, src) + 1e-9 < cost:
        raise PaymentError(f"Not enough money: you need {shortfall:,.2f} {currency} more and your {src} wallet "
                           f"cannot cover the {cost:,.2f} {src} conversion.")
    q = sandbox.quote(cost, src, currency, "remitlite")
    fx = Transaction(user_id=user.id, kind="FX", direction="OUT", amount=cost, currency=src,
                     amount_usd=sandbox.to_usd(cost, src), counterparty=f"Own {currency} wallet", channel="INTERNAL",
                     provider=q["provider"], fee=q["fee"], fx_rate=q["rate"],
                     memo=f"Converted to {shortfall:,.2f} {currency}", initiated_by=initiated_by,
                     status="PENDING", tier="T2")
    db.add(fx)
    db.flush()
    step = {"transaction_id": fx.id, "amount": cost, "from": src, "to": currency, "receive": round(shortfall, 2),
            "rate": q["rate"], "fee": q["fee"]}
    return step, fx


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
    decision = decide_payment(kind="TUITION", risk=risk, features=features, verification_status=ver["status"])

    plan, extra_txs = None, []
    if decision.decision != "BLOCK":
        shortfall = amount - _balance(db, user, currency)
        if shortfall > 1e-9:  # not enough in this currency: plan a conversion, verified together with the payment
            plan, fx = _plan_conversion(db, user, currency, shortfall, initiated_by)
            extra_txs = [fx]

    name = payee.name if payee else (payee_name or "Unknown payee")
    tx = Transaction(user_id=user.id, kind="TUITION", direction="OUT", amount=amount, currency=currency,
                     amount_usd=amount_usd, payee_id=payee.id if payee else None, counterparty=name,
                     counterparty_account=payee.account_ref if payee else account_ref, channel="BANK_TRANSFER",
                     memo=f"Tuition{(' - ' + semester) if semester else ''}", features=features,
                     initiated_by=initiated_by, status="PENDING")
    if plan:
        summary = (f"Convert {plan['amount']:,.2f} {plan['from']} to {plan['receive']:,.2f} {currency}, "
                   f"then pay {amount:,.2f} {currency} tuition to {name}")
    else:
        summary = f"Pay {amount:,.2f} {currency} tuition to {name}"
    args = {"amount": amount, "currency": currency, "payee_name": payee_name, "account_ref": account_ref,
            "semester": semester, "from_request_text": bool(request_text),
            "invoice_id": invoice.id if invoice else None, "convert": plan}
    steps = ([{"step": "convert", **{k: plan[k] for k in ("amount", "from", "receive", "to", "fee")}}] if plan else [])
    steps.append({"step": "pay", "amount": amount, "currency": currency, "to": name})
    return _finalize(db, user, session_id=session_id, tool="pay_tuition", args=args, tx=tx, risk=risk,
                     decision=decision, summary=summary, extra_txs=extra_txs,
                     extra={"payee_verification": ver, "request_analysis": analysis, "plan": steps,
                            "invoice": {"semester": invoice.semester, "due_date": invoice.due_date}
                            if invoice else None})


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
    decision = decide_payment(kind="REMITTANCE_OUT", risk=risk, features=features, verification_status=None)
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
    """Prepare a conversion between the student's own wallets; it runs after verification."""
    src, dst = sandbox.check_currency(from_currency), sandbox.check_currency(to_currency)
    if src == dst:
        raise PaymentError("Choose two different currencies")
    _check_funds(db, user, src, amount)
    q = sandbox.quote(amount, src, dst, "remitlite")
    tx = Transaction(user_id=user.id, kind="FX", direction="OUT", amount=amount, currency=src,
                     amount_usd=sandbox.to_usd(amount, src), counterparty=f"Own {dst} wallet", channel="INTERNAL",
                     provider=q["provider"], fee=q["fee"], fx_rate=q["rate"],
                     memo=f"Converted to {q['receive_amount']:,.2f} {dst}", initiated_by=initiated_by,
                     status="PENDING", tier="T2")
    db.add(tx)
    db.flush()
    decision = decide_conversion()
    summary = f"Convert {amount:,.2f} {src} to {q['receive_amount']:,.2f} {dst}"
    action = AgentAction(user_id=user.id, session_id=session_id, tool="convert_currency",
                         args={"fx": {"amount": amount, "from": src, "to": dst, "receive": q["receive_amount"]}},
                         tier="T2", summary=summary, transaction_id=tx.id, status="PENDING")
    db.add(action)
    db.flush()
    _await_verification(db, user, action, [tx], initiated_by)
    action.result = {"status": action.status, "summary": summary, "policy": decision.as_dict(), "quote": q,
                     "action_id": action.id, "transaction": tx_view(tx), "expires_at": _iso(action.expires_at)}
    audit.record(db, user_id=user.id, actor="AGENT" if initiated_by == "AGENT" else "STUDENT",
                 event="FX_AWAITING_VERIFICATION", tier="T2",
                 details={"action_id": action.id, "amount": amount, "from": src, "to": dst,
                          "receive": q["receive_amount"]})
    return dict(action.result)


def maybe_mule_alert(db: Session, user: User, tx: Transaction):
    """Warn the moment a large amount arrives from a sender the student has never received money from."""
    if tx.direction != "IN" or tx.amount_usd < MULE_ALERT_MIN_USD:
        return None
    from app.services.notify import already_sent

    earlier = db.scalar(select(Transaction.id).where(
        Transaction.user_id == user.id, Transaction.direction == "IN", Transaction.status == "COMPLETED",
        Transaction.counterparty == tx.counterparty, Transaction.id != tx.id).limit(1))
    if earlier or already_sent(db, user.id, "MULE_ALERT", f"tx:{tx.id}"):
        return None
    return notify(db, user.id, kind="MULE_ALERT", title="Money from someone new",
                  body=(f"You received {tx.amount:,.0f} {tx.currency} from {tx.counterparty}. If anyone asks you to "
                        f"send it on, it's a money-mule scam. Don't forward it; we can help you return it."),
                  data={"key": f"tx:{tx.id}", "transaction_id": tx.id})


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
    maybe_mule_alert(db, user, tx)
    return tx_view(tx)


def _settle_fx(tx: Transaction, db: Session, step: dict):
    sandbox.debit(db, tx.user_id, step["from"], step["amount"])
    sandbox.credit(db, tx.user_id, step["to"], step["receive"])
    tx.status, tx.executed_at = "COMPLETED", _now()


def _get_open_action(db: Session, user: User, action_id: int) -> AgentAction:
    a = db.get(AgentAction, action_id)
    if a is None or a.user_id != user.id:
        raise PaymentError("Payment not found")
    if a.status != "AWAITING_VERIFICATION":
        raise PaymentError(f"This payment is {a.status.lower().replace('_', ' ')} and cannot be verified")
    if _aware(a.expires_at) < _now():
        _expire(db, a)
        raise PaymentError("This verification request expired. Ask the agent to prepare it again.")
    return a


def _related_txs(db: Session, a: AgentAction) -> list[Transaction]:
    txs = [db.get(Transaction, a.transaction_id)]
    conv = (a.args or {}).get("convert")
    if conv:
        txs.insert(0, db.get(Transaction, conv["transaction_id"]))
    return txs


def _expire(db: Session, a: AgentAction):
    a.status, a.verification_nonce = "EXPIRED", None
    for t in _related_txs(db, a):
        t.status = "EXPIRED"
    audit.record(db, user_id=a.user_id, actor="SYSTEM", event="PAYMENT_EXPIRED", tier=a.tier,
                 details={"action_id": a.id})
    db.commit()


def challenge(db: Session, user: User, action_id: int) -> dict:
    a = _get_open_action(db, user, action_id)
    return {"action_id": a.id, "challenge": devices.challenge_text(a), "summary": a.summary,
            "expires_at": _iso(a.expires_at), "mode": settings.VERIFICATION_MODE}


def verify_action(db: Session, user: User, action_id: int, *, device_id: int | None = None,
                  signature: str | None = None, sandbox_ok: bool = False) -> dict:
    a = _get_open_action(db, user, action_id)
    if settings.VERIFICATION_MODE == "sandbox" and sandbox_ok and settings.ENVIRONMENT != "production":
        method = "sandbox"
    else:
        if device_id is None or not signature:
            raise devices.VerificationError("Verify on your registered phone: a device signature is required")
        devices.check_signature(db, user, a, device_id, signature)
        method = f"device:{device_id}"

    args = a.args or {}
    conv = args.get("convert")
    if conv:
        _settle_fx(db.get(Transaction, conv["transaction_id"]), db, conv)
    tx = db.get(Transaction, a.transaction_id)
    if tx.kind == "FX" and args.get("fx"):
        _settle_fx(tx, db, args["fx"])
    else:
        sandbox.settle(db, tx)  # re-checks the balance at execution time
    inv_id = args.get("invoice_id")
    if inv_id:
        inv = db.get(TuitionInvoice, inv_id)
        if inv and inv.status == "OPEN":
            inv.status, inv.transaction_id = "PAID", tx.id

    a.status, a.decided_at, a.verification_nonce = "VERIFIED", _now(), None
    receipt = receipts.build(db, tx)
    a.result = {**(a.result or {}), "status": "VERIFIED", "transaction": tx_view(tx), "receipt": receipt}
    audit.record(db, user_id=user.id, actor="STUDENT", event="PAYMENT_VERIFIED", tier=a.tier,
                 details={"action_id": a.id, "transaction_id": tx.id, "amount": tx.amount, "currency": tx.currency,
                          "counterparty": tx.counterparty, "method": method})
    notify(db, user.id, kind="PAYMENT_DONE", title="Payment complete",
           body=f"{a.summary}. Receipt {receipt['reference']}.", action_id=a.id,
           data={"receipt": receipt["reference"], "transaction_id": tx.id})
    return action_view(a)


def reject_action(db: Session, user: User, action_id: int) -> dict:
    a = _get_open_action(db, user, action_id)
    a.status, a.decided_at, a.verification_nonce = "REJECTED", _now(), None
    for t in _related_txs(db, a):
        t.status = "REJECTED"
    a.result = {**(a.result or {}), "status": "REJECTED"}
    audit.record(db, user_id=user.id, actor="STUDENT", event="PAYMENT_REJECTED", tier=a.tier,
                 details={"action_id": a.id})
    return action_view(a)
