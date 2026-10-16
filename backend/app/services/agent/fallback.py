"""
Deterministic intent parser used when no LLM is available. It calls the same tools as the LLM
agent, so payments still go through the risk engine and the permission policy.
"""

import re

from sqlalchemy.orm import Session

from sqlalchemy import select

from app.models import Transaction, User
from app.services.agent.tools import run_tool

CUR = r"(usd|cny|rmb|bdt|cad|gbp|myr|eur|taka|yuan|dollars?|\$|¥|৳)"
NUM = r"(\d[\d,]*(?:\.\d+)?)"  # starts with a digit, so a lone comma is not a number
ALIASES = {"rmb": "CNY", "yuan": "CNY", "¥": "CNY", "taka": "BDT", "৳": "BDT", "$": "USD", "dollar": "USD",
           "dollars": "USD"}


def _cur(token: str | None, default: str | None = None) -> str | None:
    if not token:
        return default
    t = token.lower()
    return ALIASES.get(t, t.upper())


SEMESTER = r"\b(spring|summer|fall|autumn|winter)\s+(20\d\d)\b"
# Wording that scam messages use to rush a student into paying someone who isn't the university.
SCAM_SIGNALS = (r"\b(urgent\w*|act now|today only|limited time|\d+\s?% off|discount|wechat|alipay|gift ?cards?|"
                r"crypto|usdt|our agent|agent account|personal account|or (?:your )?(?:seat|enrol\w*) (?:is|will be) cancel\w*)\b"
                r"|\b(can|could|should) (you|i) pay this\b|\bpay this\?")


def _semester(text: str) -> str | None:
    m = re.search(SEMESTER, text, re.I)
    return f"{m.group(1).title()} {m.group(2)}" if m else None


def _amount(text: str):
    text = re.sub(SEMESTER, " ", text, flags=re.I)  # "Spring 2027" is a semester, not 2,027
    m = re.search(rf"{CUR}\s?{NUM}|{NUM}\s?{CUR}?", text, re.I)
    if not m:
        return None, None
    if m.group(2):
        return float(m.group(2).replace(",", "")), _cur(m.group(1))
    return float(m.group(3).replace(",", "")), _cur(m.group(4))


def _status_line(result: dict) -> str:
    s = result.get("status")
    if s == "ERROR":
        return f"I couldn't do that: {result['error']}"
    risk = result.get("risk", {})
    risk_txt = f" Fraud risk is {risk.get('level', '').lower()} ({risk.get('score', 0):.0%})." if risk else ""
    if s == "AWAITING_VERIFICATION":
        convert = next((p for p in result.get("plan") or [] if p.get("step") == "convert"), None)
        if convert:
            pay = next(p for p in result["plan"] if p.get("step") == "pay")
            return (f"You're {convert['receive']:,.0f} {convert['to']} short, so I'll convert {convert['amount']:,.0f} "
                    f"{convert['from']} first, then pay {pay['amount']:,.0f} {pay['currency']}.{risk_txt} One verification "
                    f"covers both. Please complete verification to complete the payment.")
        return f"Ready: {result['summary']}.{risk_txt} Please complete verification to complete the payment."
    if s == "BLOCKED":
        rules = "; ".join(result["policy"]["rules"])
        reasons = "; ".join(r["text"] for r in risk.get("reasons", []))
        return f"I blocked this: {result['summary']}. Why: {rules}." + (f" Signals: {reasons}." if reasons else "")
    return ""


def respond(db: Session, user: User, session_id: str, message: str, actions: list) -> str:
    text = message.strip()
    low = text.lower()

    def call(tool, **args):
        r = run_tool(db, user, session_id, tool, args)
        actions.append({"tool": tool, **r})
        return r

    long_paste = len(text) > 140 or "\n" in text
    if long_paste or re.search(SCAM_SIGNALS, low) or re.search(r"\b(is this (real|legit|a scam|safe)|scam\??|check this)\b", low):
        body = re.sub(r"^.*?(is this (real|legit|a scam|safe)\??|check this:?)", "", text, flags=re.I | re.S).strip() or text
        r = call("analyze_payment_request", text=body)
        if r.get("status") == "ERROR":
            return _status_line(r)
        n = len(r.get("red_flags", []))
        verdict = {"LIKELY_SCAM": "I won't pay this. It looks like a scam",
                   "CAUTION": "Be careful with this request",
                   "NO_RED_FLAGS_FOUND": "I found no red flags in this message"}[r["verdict"]]
        found = f": {n} red flag{'s' if n != 1 else ''}" if n else ""
        pv = r.get("payee_verification", {})
        unverified = (" and the account isn't a verified university account"
                      if pv.get("status") == "UNKNOWN" and n else
                      ". The account isn't a verified university account" if pv.get("status") == "UNKNOWN" else "")
        op = r.get("second_opinion", {})
        ai = f" AI second opinion: {op['explanation']}" if op.get("available") else ""
        advice = (" Don't pay it. Pay only through your university's official account."
                  if r["verdict"] != "NO_RED_FLAGS_FOUND" else
                  " Still, check the payee against your university's official portal before paying.")
        return f"{verdict}{found}{unverified}.{ai}{advice}"

    if re.search(r"\b(stranger|someone i (?:don'?t|do not) know|unknown (?:sender|person)|money[- ]?mule|by mistake|"
                 r"sent (?:to )?me (?:by )?(?:mistake|accident)|wrong(?:ly)? sent)\b", low) and \
            re.search(r"\b(money|received|transfer|return|refund|send (?:it )?back|got)\b", low):
        return _return_money_help(db, user)

    m = re.search(rf"\b(?:every|each)\s+month\b.*?{NUM}\s?{CUR}?.*?\bto\s+(?:my\s+)?([a-z][\w .'-]{{1,40}}?)"
                  rf"(?:\s+on\s+(?:the\s+)?(\d{{1,2}})(?:st|nd|rd|th)?)?$", low)
    if m:
        r = call("create_standing_instruction", recipient=m.group(3).strip(), amount=float(m.group(1).replace(",", "")),
                 currency=_cur(m.group(2)), day_of_month=int(m.group(4) or 1))
        if r["status"] == "ERROR":
            return _status_line(r)
        si = r["standing_instruction"]
        return (f"Set up: {si['amount']:,.0f} {si['currency']} to {si['recipient']} on day {si['day_of_month']} of "
                f"every month. I'll prepare it that morning and ask you to verify it before anything is sent.")

    if re.search(r"\b(deadline|due|remind\w*)\b", low):
        r = call("get_tuition_reminders")
        return " ".join(x["message"] for x in r.get("reminders", [])) or "You have no open tuition invoices."

    if re.search(r"\b(tuition|semester fee|course fee|university fee)\b", low):
        amount, cur = _amount(text)
        r = call("pay_tuition", amount=amount, currency=cur, semester=_semester(text))
        return _status_line(r)

    if re.search(r"\b(convert|exchange)\b", low):
        m = re.search(rf"{NUM}\s?{CUR}\s+(?:to|into)\s+{CUR}", low, re.I)
        if m:
            r = call("convert_currency", amount=float(m.group(1).replace(",", "")), from_currency=_cur(m.group(2)),
                     to_currency=_cur(m.group(3)))
            return _status_line(r)
        return "Tell me the amount and currencies, for example: convert 5000 BDT to CNY."

    if re.search(r"\b(compare|cheapest|best rate|fees? to send)\b", low):
        amount, cur = _amount(text)
        dst = _cur((re.search(rf"\bto\s+{CUR}", low) or [None, None])[1], user.home_currency)
        r = call("compare_remittance_providers", amount=amount or 1000, from_currency=cur or user.study_currency,
                 to_currency=dst)
        best = r["options"][0]
        return (f"Cheapest: {best['provider']}: they receive {best['receive_amount']:,.2f} {best['receive_currency']} "
                f"(total cost {best['total_cost_pct']}%). A bank wire costs "
                f"{next(o['total_cost_pct'] for o in r['options'] if o['provider_id'] == 'bank_wire')}%.")

    m = re.search(r"\b(send|transfer|pay)\b\s+(.*?)\s+\bto\s+(?:my\s+)?([a-z][\w .'-]{1,40})$", low)
    if m:
        amount, cur = _amount(m.group(2))
        if amount:
            r = call("send_remittance", recipient=m.group(3).strip(), amount=amount, currency=cur)
            return _status_line(r)

    if re.search(r"\b(balance|wallet|how much (money|do i have))\b", low):
        r = call("get_wallet_balances")
        return "Your balances: " + ", ".join(f"{b['balance']:,.2f} {b['currency']}" for b in r["balances"]) + "."

    if re.search(r"\b(receipt|proof)\b", low):
        m = re.search(r"(?:transaction|tx|#)\s*#?(\d+)", low)
        r = call("get_payment_receipt", transaction_id=int(m.group(1)) if m else None)
        if r["status"] == "ERROR":
            return _status_line(r)
        rc = r["receipt"]
        return (f"Receipt {rc['reference']}: {rc['type']} of {rc['amount']:,.2f} {rc['currency']} to "
                f"{rc['counterparty']} on {rc['executed_at'][:10]}. Verification code {rc['verification_code']}. "
                f"Download the PDF from {r['pdf_path']}.")

    if re.search(r"\b(transactions|history|recent)\b", low):
        r = call("get_recent_transactions", limit=5)
        return "Recent: " + "; ".join(f"{t['kind']} {t['amount']:,.0f} {t['currency']} ({t['status']})"
                                      for t in r["transactions"]) + "."

    return ("I can pay your tuition, remind you of deadlines, send money home, set up monthly payments, compare "
            "transfer fees, convert currencies, give payment receipts, or check if a payment request is a scam. "
            "Every payment waits for your verification. Try: \"pay my tuition\" or \"send 2000 CNY to mother\".")


def _return_money_help(db: Session, user: User) -> str:
    """Safe steps for money that arrived from a stranger. Prepares nothing: moving it on is the scam."""
    incoming = db.scalars(select(Transaction).where(Transaction.user_id == user.id, Transaction.direction == "IN",
                                                    Transaction.status == "COMPLETED")
                          .order_by(Transaction.created_at.desc(), Transaction.id.desc())).all()
    senders = [t.counterparty for t in incoming]
    first_time = next((t for t in incoming if senders.count(t.counterparty) == 1), None)
    what = (f"the {first_time.amount:,.0f} {first_time.currency} from {first_time.counterparty}" if first_time
            else "money from someone you don't know")
    return (f"Here's how to handle {what} safely. 1) Don't send it on to anyone, and don't send it \"back\" to a "
            "different account: that is exactly how money-mule and overpayment scams work. 2) Ask your bank to "
            "return it to the original sender (a recall or reversal); the bank sends it back through the same channel. "
            "3) Keep the messages and report it to your bank and your university's international office. "
            "MoneyMate will block any transfer that tries to forward this money.")
