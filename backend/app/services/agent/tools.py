"""Tools the agent can call. Read tools run at tier T0; money tools go through payments.py and the policy engine."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import AgentAction, Payee, Transaction, User
from app.services import audit, payments, sandbox, verification

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
    {"name": "get_credit_passport",
     "description": "The student's verified payment-history report (Financial Passport) for landlords or banks.",
     "parameters": _obj({})},
    {"name": "pay_tuition",
     "description": ("Pay tuition. With no payee, pays the student's registered university. If the student pasted an "
                     "invoice or message, pass it as request_text so it is checked. The policy engine decides whether it "
                     "runs, needs the student's confirmation in the app, or is blocked."),
     "parameters": _obj({"amount": NUM, "currency": STR, "payee_name": STR, "account_ref": STR, "semester": STR,
                         "request_text": STR})},
    {"name": "send_remittance",
     "description": ("Send money to a person abroad or at home (e.g. family). Picks the cheapest provider unless one is "
                     "given. New recipients need account_ref and country. currency = what the student pays in."),
     "parameters": _obj({"recipient": STR, "amount": NUM, "currency": STR, "receive_currency": STR,
                         "provider_id": STR, "account_ref": STR, "country": STR,
                         "channel": {"type": "string", "enum": ["BANK_TRANSFER", "EWALLET_P2P", "CRYPTO", "GIFT_CARD"]},
                         "request_text": STR},
                        ["recipient", "amount"])},
    {"name": "convert_currency", "description": "Convert money between the student's own wallets.",
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
            result = {"balances": sandbox.balances(db, user.id), "rates_as_of": sandbox.RATES_AS_OF}
            summary = "Checked wallet balances"
        elif name == "get_fx_quote":
            result = sandbox.quote(float(args["amount"]), args["from_currency"].upper(), args["to_currency"].upper())
            summary = f"FX quote {args['amount']} {args['from_currency']} -> {args['to_currency']}"
        elif name == "compare_remittance_providers":
            result = {"options": sandbox.compare(float(args["amount"]), args["from_currency"].upper(),
                                                 args["to_currency"].upper()), "rates_as_of": sandbox.RATES_AS_OF}
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
            result = verification.analyze_request(db, args["text"])
            summary = f"Analysed payment request: {result['verdict']}"
        elif name == "get_recent_transactions":
            rows = db.scalars(select(Transaction).where(Transaction.user_id == user.id)
                              .order_by(Transaction.created_at.desc()).limit(int(args.get("limit", 8)))).all()
            result = {"transactions": [payments.tx_view(t) for t in rows]}
            summary = "Listed recent transactions"
        elif name == "get_credit_passport":
            result = payments.credit_passport(db, user)
            summary = "Generated Financial Passport"
        else:
            return {"status": "ERROR", "error": f"Unknown tool {name}"}
        result = {"status": "READ", **result}
        result["action_id"] = _record_read(db, user, session_id, name, args, summary, result)
        return result
    except (payments.PaymentError, sandbox.SandboxError, KeyError, ValueError) as e:
        return {"status": "ERROR", "error": str(e) if not isinstance(e, KeyError) else f"Missing argument {e}"}
