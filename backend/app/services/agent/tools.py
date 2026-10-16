"""Tools the agent can call. Read tools run at tier T0; money tools go through payments.py and the policy engine."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import AgentAction, Payee, Transaction, User
from app.services import audit, history, payments, receipts, reminders, sandbox, standing, verification
from app.services.agent.second_opinion import analyze_with_second_opinion

STR, NUM = {"type": "string"}, {"type": "number"}


def _obj(props: dict, required: list[str] | None = None) -> dict:
    return {"type": "object", "properties": props, "required": required or []}


DECLARATIONS = [
    {"name": "get_wallet_balances", "description": "Show the student's sandbox wallet balances in every currency.",
     "parameters": _obj({})},
    {"name": "get_fx_quote", "description": "Quote converting an amount between two currencies (mid-market and after fees).",
     "parameters": _obj({"amount": NUM, "from_currency": STR, "to_currency": STR},
                        ["amount", "from_currency", "to_currency"])},
    {"name": "compare_remittance_providers",
     "description": "Compare remittance providers (fees + exchange-rate margin) for sending money abroad. Returns best first.",
     "parameters": _obj({"amount": NUM, "from_currency": STR, "to_currency": STR},
                        ["amount", "from_currency", "to_currency"])},
    {"name": "list_recipients", "description": "List the student's saved recipients and their registered university.",
     "parameters": _obj({})},
    {"name": "verify_payee",
     "description": "Check a payee name and/or bank account against the verified institution registry. Detects impersonation.",
     "parameters": _obj({"name": STR, "account_ref": STR})},
    {"name": "analyze_payment_request",
     "description": "Analyse a pasted invoice, email, SMS or chat message asking for payment. Extracts payee, amount, account and lists scam red flags.",
     "parameters": _obj({"text": STR}, ["text"])},
    {"name": "get_recent_transactions", "description": "Recent transactions with their risk decisions.",
     "parameters": _obj({"limit": {"type": "integer"}})},
    {"name": "get_tuition_reminders",
     "description": ("Upcoming tuition deadlines: days left, whether the wallet covers each invoice, and what "
                     "converting from the home currency would cost if not."),
     "parameters": _obj({})},
    {"name": "get_payment_receipt",
     "description": ("Payment proof for a completed transaction: reference number, details and a verification code "
                     "anyone can check. Without transaction_id, returns the most recent completed payment."),
     "parameters": _obj({"transaction_id": {"type": "integer"}})},
    {"name": "get_payment_history",
     "description": ("The student's on-time payment record (rent, family support, tuition) for the last N months: "
                     "how many payments were due, paid on time, late or missed. Use it when the student needs proof of "
                     "reliable payments for a landlord, bank or university (they have no local credit history). "
                     "The student can issue a verifiable report from the Payment history screen."),
     "parameters": _obj({"months": {"type": "integer"}})},
    {"name": "pay_tuition",
     "description": ("Prepare a tuition payment. With no payee, uses the student's registered university and open "
                     "invoice. If the wallet is short, it plans the currency conversion too, verified together. If the "
                     "student pasted an invoice or message, pass it as request_text so it is checked. Nothing is paid "
                     "until the student verifies on their phone; risky payments are blocked."),
     "parameters": _obj({"amount": NUM, "currency": STR, "payee_name": STR, "account_ref": STR, "semester": STR,
                         "request_text": STR})},
    {"name": "send_remittance",
     "description": ("Prepare a transfer to a person abroad or at home (e.g. family). Picks the cheapest provider unless "
                     "one is given. New recipients need account_ref and country. currency = what the student pays in. "
                     "It is sent only after the student verifies on their phone."),
     "parameters": _obj({"recipient": STR, "amount": NUM, "currency": STR, "receive_currency": STR,
                         "provider_id": STR, "account_ref": STR, "country": STR,
                         "channel": {"type": "string", "enum": ["BANK_TRANSFER", "EWALLET_P2P", "CRYPTO", "GIFT_CARD"]},
                         "request_text": STR},
                        ["recipient", "amount"])},
    {"name": "create_standing_instruction",
     "description": ("Set up a recurring payment (rent, monthly money for family) on a day of the month (1-28). "
                     "On that day the agent prepares it and the student verifies it."),
     "parameters": _obj({"recipient": STR, "amount": NUM, "day_of_month": {"type": "integer"}, "currency": STR,
                         "note": STR}, ["recipient", "amount", "day_of_month"])},
    {"name": "list_standing_instructions", "description": "List the student's recurring payments.",
     "parameters": _obj({})},
    {"name": "convert_currency", "description": "Prepare a conversion between the student's own wallets (verified before it runs).",
     "parameters": _obj({"amount": NUM, "from_currency": STR, "to_currency": STR},
                        ["amount", "from_currency", "to_currency"])},
]

MONEY_TOOLS = {"pay_tuition", "send_remittance", "convert_currency"}


def _record_read(db: Session, user: User, session_id: str, tool: str, args: dict, summary: str, result: dict):
    a = AgentAction(user_id=user.id, session_id=session_id, tool=tool, args=args, tier="T0", status="READ",
                    summary=summary, result=result)
    db.add(a)
    db.flush()
    audit.record(db, user_id=user.id, actor="AGENT", event="TOOL_READ", tier="T0",
                 details={"action_id": a.id, "tool": tool, "args": args})
    return a.id


def run_tool(db: Session, user: User, session_id: str, name: str, args: dict) -> dict:
    """Execute a tool call. Never raises for business errors; returns {'status': 'ERROR', ...} instead."""
    args = {k: v for k, v in (args or {}).items() if v not in (None, "")}
    try:
        if name in MONEY_TOOLS:
            fn = getattr(payments, name)
            return fn(db, user, session_id=session_id, initiated_by="AGENT", **args)

        if name == "get_wallet_balances":
            fx = sandbox.rates_info()
            result = {"balances": sandbox.balances(db, user.id), "rates_as_of": fx["as_of"], "rates_source": fx["source"]}
            summary = "Checked wallet balances"
        elif name == "get_fx_quote":
            result = sandbox.quote(float(args["amount"]), args["from_currency"].upper(), args["to_currency"].upper())
            summary = f"FX quote {args['amount']} {args['from_currency']} -> {args['to_currency']}"
        elif name == "compare_remittance_providers":
            result = {"options": sandbox.compare(float(args["amount"]), args["from_currency"].upper(),
                                                 args["to_currency"].upper()),
                      "rates_as_of": sandbox.rates_info()["as_of"], "rates_source": sandbox.rates_info()["source"]}
            summary = f"Compared providers for {args['amount']} {args['from_currency']}"
        elif name == "list_recipients":
            mine = db.scalars(select(Payee).where(Payee.owner_user_id == user.id)).all()
            uni = db.get(Payee, user.university_payee_id) if user.university_payee_id else None
            result = {"recipients": [{"name": p.name, "relationship": p.relationship, "country": p.country,
                                      "currency": p.currency} for p in mine],
                      "registered_university": uni.name if uni else None}
            summary = "Listed recipients"
        elif name == "verify_payee":
            result = verification.verify_payee(db, args.get("name"), args.get("account_ref"))
            summary = f"Verified payee: {result['status']}"
        elif name == "analyze_payment_request":
            result = analyze_with_second_opinion(db, args["text"])
            summary = f"Analysed payment request: {result['verdict']}"
        elif name == "get_recent_transactions":
            rows = db.scalars(select(Transaction).where(Transaction.user_id == user.id)
                              .order_by(Transaction.created_at.desc()).limit(int(args.get("limit", 8)))).all()
            result = {"transactions": [payments.tx_view(t) for t in rows]}
            summary = "Listed recent transactions"
        elif name == "create_standing_instruction":
            si = standing.create(db, user, recipient=args["recipient"], amount=float(args["amount"]),
                                 day_of_month=int(args["day_of_month"]), currency=args.get("currency"),
                                 note=args.get("note"))
            result = {"standing_instruction": standing.view(db, si)}
            summary = f"Set up {si.amount:,.0f} {si.currency} every month on day {si.day_of_month}"
        elif name == "list_standing_instructions":
            from app.models import StandingInstruction
            rows = db.scalars(select(StandingInstruction).where(StandingInstruction.user_id == user.id)).all()
            result = {"standing_instructions": [standing.view(db, si) for si in rows]}
            summary = "Listed standing instructions"
        elif name == "get_tuition_reminders":
            result = {"reminders": reminders.tuition_reminders(db, user)}
            summary = "Checked tuition deadlines"
        elif name == "get_payment_history":
            rec = history.build(db, user, int(args.get("months", 6)))
            result = {k: rec[k] for k in ("months", "period_start", "period_end", "summary", "categories", "upcoming")}
            result["how_to_share"] = "Profile → Payment history → Issue verifiable report (PDF with a QR code)"
            summary = f"Checked payment history: {rec['summary']['on_time']}/{rec['summary']['payments_due']} on time"
        elif name == "get_payment_receipt":
            q = select(Transaction).where(Transaction.user_id == user.id, Transaction.status == "COMPLETED")
            if args.get("transaction_id"):
                q = q.where(Transaction.id == int(args["transaction_id"]))
            else:
                q = q.where(Transaction.direction == "OUT")
            tx = db.scalar(q.order_by(Transaction.executed_at.desc(), Transaction.id.desc()).limit(1))
            if tx is None:
                return {"status": "ERROR", "error": "No completed transaction found"}
            result = {"receipt": receipts.build(db, tx), "pdf_path": f"/api/transactions/{tx.id}/receipt.pdf"}
            summary = f"Issued receipt {result['receipt']['reference']}"
        else:
            return {"status": "ERROR", "error": f"Unknown tool {name}"}
        result = {"status": "READ", **result}
        result["action_id"] = _record_read(db, user, session_id, name, args, summary, result)
        return result
    except (payments.PaymentError, sandbox.SandboxError, receipts.ReceiptError, standing.StandingError,
            history.HistoryError, KeyError, ValueError) as e:
        return {"status": "ERROR", "error": str(e) if not isinstance(e, KeyError) else f"Missing argument {e}"}
