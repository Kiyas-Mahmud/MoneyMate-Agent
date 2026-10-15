"""
Deterministic intent parser used when no LLM is available. It calls the same tools as the LLM
agent, so payments still go through the risk engine and the permission policy.
"""

import re

from sqlalchemy.orm import Session

from app.models import User
from app.services.agent.tools import run_tool

CUR = r"(usd|cny|rmb|bdt|cad|gbp|myr|eur|taka|yuan|dollars?|\$|¥|৳)"
NUM = r"([\d,]+(?:\.\d+)?)"
ALIASES = {"rmb": "CNY", "yuan": "CNY", "¥": "CNY", "taka": "BDT", "৳": "BDT", "$": "USD", "dollar": "USD",
           "dollars": "USD"}


def _cur(token: str | None, default: str | None = None) -> str | None:
    if not token:
        return default
    t = token.lower()
    return ALIASES.get(t, t.upper())


def _amount(text: str):
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
    risk_txt = f" Risk: {risk.get('level')} ({risk.get('score', 0):.0%})." if risk else ""
    if s == "AWAITING_VERIFICATION":
        return (f"Prepared: {result['summary']}.{risk_txt} I sent you a notification. Please complete verification "
                f"on your phone to complete the payment.")
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
    if long_paste or re.search(r"\b(is this (real|legit|a scam|safe)|scam\??|check this)\b", low):
        body = re.sub(r"^.*?(is this (real|legit|a scam|safe)\??|check this:?)", "", text, flags=re.I | re.S).strip() or text
        r = call("analyze_payment_request", text=body)
        flags = "; ".join(f["explanation"] for f in r.get("red_flags", [])) or "no rule-based red flags found"
        verdict = {"LIKELY_SCAM": "This looks like a SCAM.", "CAUTION": "Be careful with this request.",
                   "NO_RED_FLAGS_FOUND": "I found no red flags."}[r["verdict"]]
        pv = r.get("payee_verification", {})
        tail = f" Payee check: {pv.get('status')}." if pv.get("status") else ""
        op = r.get("second_opinion", {})
        ai = f" AI second opinion: {op['explanation']}" if op.get("available") else ""
        return (f"{verdict} {flags}.{tail}{ai} Do not pay until it is verified with your university's "
                f"official portal.")

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
        r = call("pay_tuition", amount=amount, currency=cur)
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
