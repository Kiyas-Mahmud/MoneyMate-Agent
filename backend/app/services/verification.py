"""
Payee verification against the institution registry, and red-flag analysis of payment requests
(tuition invoices, "agent" messages, remittance requests). Deterministic, so it works without an LLM
and cannot be talked out of its result by text inside the request.
"""

import re
from difflib import SequenceMatcher

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.models import Payee

URGENCY = r"\b(urgent|immediately|within (24|48) hours|today only|last chance|final notice|act now|asap)\b"
DISCOUNT = r"\b(discount|\d{1,2}\s?% off|special offer|reduced fee|cheaper rate|cashback|save \d+)\b"
THREAT = r"\b(deport|visa (will be )?(cancel|revok)|arrest|police|immigration (officer|case)|legal action|penalty|enrol(l)?ment (will be )?cancel)\b"
RISKY_CHANNEL = r"\b(bitcoin|btc|usdt|crypto|gift ?card|itunes|steam card|wechat (pay )?(transfer|to)|alipay to|western union to|personal account|money ?gram)\b"
SECRECY = r"\b(don'?t tell|keep (this )?(secret|confidential)|do not contact (the )?(university|school))\b"
AMOUNT = r"(?:(USD|CNY|RMB|BDT|CAD|GBP|MYR|EUR|\$|¥|৳|£)\s?([\d,]+(?:\.\d+)?)|([\d,]+(?:\.\d+)?)\s?(USD|CNY|RMB|BDT|CAD|GBP|MYR|EUR|yuan|taka|dollars?))"
ACCOUNT = r"\b(?:account|a/c|acct|iban)(?:\s*(?:no\.?|number|#))?\s*[:#]?\s*([A-Z0-9][A-Z0-9\- ]{5,30}[A-Z0-9])"

CURRENCY_ALIASES = {"$": "USD", "dollar": "USD", "dollars": "USD", "¥": "CNY", "rmb": "CNY", "yuan": "CNY",
                    "৳": "BDT", "taka": "BDT", "£": "GBP"}


def _norm_account(acct: str) -> str:
    return re.sub(r"[\s\-]", "", acct or "").upper()


def _similar(a: str, b: str) -> float:
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def registry(db: Session):
    return db.scalars(select(Payee).where(Payee.owner_user_id.is_(None), Payee.verified.is_(True))).all()


def verify_payee(db: Session, name: str | None = None, account_ref: str | None = None) -> dict:
    """
    VERIFIED   : account matches an official registry account
    IMPERSONATION : name looks like a registered institution but the account is different
    UNKNOWN    : not in the registry (could be a private person or an unlisted business)
    """
    acct = _norm_account(account_ref) if account_ref else ""
    entries = registry(db)
    if acct:
        for p in entries:
            if _norm_account(p.account_ref) == acct:
                return {"status": "VERIFIED", "payee_id": p.id, "official_name": p.name, "country": p.country,
                        "currency": p.currency, "bank": p.bank_name, "source": p.verification_source}
    if name:
        best = max(entries, key=lambda p: _similar(name, p.name), default=None)
        if best is not None and _similar(name, best.name) >= 0.72:
            if acct:
                return {"status": "IMPERSONATION", "claimed_name": name, "official_name": best.name,
                        "official_account_hint": "****" + _norm_account(best.account_ref)[-4:],
                        "message": f"The name matches {best.name}, but this account is NOT its official account."}
            return {"status": "VERIFIED", "payee_id": best.id, "official_name": best.name, "country": best.country,
                    "currency": best.currency, "bank": best.bank_name, "source": best.verification_source,
                    "note": "Matched by name; the official account on file will be used."}
    return {"status": "UNKNOWN", "message": "This payee is not in the verified institution registry."}


def find_user_payee(db: Session, user_id: int, name: str) -> Payee | None:
    payees = db.scalars(select(Payee).where(or_(Payee.owner_user_id == user_id))).all()
    name_l = name.lower().strip()
    for p in payees:
        if name_l in (p.name.lower(), (p.relationship or "").lower()):
            return p
    best = max(payees, key=lambda p: _similar(name, p.name), default=None)
    return best if best is not None and _similar(name, best.name) >= 0.6 else None


def analyze_request(db: Session, text: str) -> dict:
    """Extract payee/amount/account from free text and list red flags."""
    t = text or ""
    flags = []
    checks = [
        (URGENCY, "URGENCY", "Pushes you to pay immediately"),
        (DISCOUNT, "DISCOUNT", "Offers a discount on fees (universities do not sell discounts through agents)"),
        (THREAT, "THREAT", "Threatens visa, enrolment or legal trouble"),
        (RISKY_CHANNEL, "RISKY_CHANNEL", "Asks for crypto, gift cards or a transfer to a personal account / e-wallet"),
        (SECRECY, "SECRECY", "Asks you to keep it secret or not contact the university"),
    ]
    for pattern, code, text_ in checks:
        m = re.search(pattern, t, re.I)
        if m:
            flags.append({"code": code, "evidence": m.group(0), "explanation": text_})

    amount = currency = None
    m = re.search(AMOUNT, t, re.I)
    if m:
        cur = (m.group(1) or m.group(4) or "").lower()
        num = m.group(2) or m.group(3)
        currency = CURRENCY_ALIASES.get(cur, cur.upper()) if cur else None
        amount = float(num.replace(",", ""))

    acct_m = re.search(ACCOUNT, t, re.I)
    account = acct_m.group(1).strip() if acct_m else None

    # Payee name: best registry name found in the text, else None
    claimed = None
    for p in registry(db):
        short = re.sub(r"\(.*?\)", "", p.name).strip()
        if short.lower() in t.lower() or _similar(short, t[:200]) > 0.8:
            claimed = p.name
            break
    verification = verify_payee(db, claimed, account) if (claimed or account) else {"status": "UNKNOWN"}
    if verification["status"] == "IMPERSONATION":
        flags.append({"code": "ACCOUNT_MISMATCH", "evidence": account,
                      "explanation": verification["message"]})

    pressure = len({f["code"] for f in flags} & {"URGENCY", "DISCOUNT", "THREAT", "SECRECY"})
    severe = any(f["code"] in ("ACCOUNT_MISMATCH", "RISKY_CHANNEL", "THREAT") for f in flags)
    verdict = "LIKELY_SCAM" if severe or pressure >= 2 else ("CAUTION" if flags else "NO_RED_FLAGS_FOUND")
    return {"verdict": verdict, "red_flags": flags, "pressure_flags": min(pressure, 3),
            "extracted": {"payee": claimed, "amount": amount, "currency": currency, "account": account},
            "payee_verification": verification}
