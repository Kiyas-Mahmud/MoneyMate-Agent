"""
Exchange rates and money requests to family at home.

When the study-currency wallet is short, the student asks a family member at home (mother, father, ...) for an
amount in the study currency. MoneyMate shows the family what to send in their currency through every provider,
cheapest first, at live mid-market rates. In the sandbox the family's transfer is simulated: the student picks the
provider the family used and the money arrives through that provider's quote. In production a licensed remittance
partner moves the money.
"""

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import FundRequest, Payee, Transaction, User
from app.services import audit, sandbox
from app.services.notify import notify

FAMILY = {"mother", "father", "parent", "brother", "sister", "sibling", "spouse", "guardian", "family", "relative",
          "uncle", "aunt"}
RATE_CURRENCIES = ("BDT", "CNY", "USD")


class FundsError(ValueError):
    pass


def is_family(payee: Payee | None, user_id: int) -> bool:
    return bool(payee and payee.owner_user_id == user_id and (payee.relationship or "").lower() in FAMILY)


# ---- exchange rates --------------------------------------------------------------------------------------

def rates(currencies=RATE_CURRENCIES, sample: float = 1000.0) -> dict:
    """Mid-market rates between the student's currencies, and the best provider for each pair."""
    info = sandbox.rates_info()
    pairs = []
    for src in currencies:
        for dst in currencies:
            if src == dst:
                continue
            best = sandbox.compare(sample * sandbox.mid_rate("USD", src) / 10, src, dst)[0]  # ~$100 transfer
            pairs.append({"from": src, "to": dst, "mid_rate": round(sandbox.mid_rate(src, dst), 6),
                          "best_provider": best["provider"], "best_rate": best["rate"],
                          "best_total_cost_pct": best["total_cost_pct"]})
    return {"as_of": info["as_of"], "source": info["source"], "live": info["source"].startswith("live"),
            "pairs": pairs, "providers": [{"id": p["id"], "name": p["name"], "fee_usd": p["fee_usd"],
                                           "fx_margin_pct": round(p["fx_margin"] * 100, 2), "eta": p["eta"]}
                                          for p in sandbox.PROVIDERS]}


# ---- what the family has to send -------------------------------------------------------------------------

def quote_to_receive(receive: float, src: str, dst: str, provider_id: str) -> dict:
    """What a family must send in `src`, through one provider, for the student to receive `receive` in `dst`."""
    p = sandbox.PROVIDER_BY_ID[provider_id]
    fee = p["fee_usd"] * sandbox.usd_rates()[sandbox.check_currency(src)]
    mid = sandbox.mid_rate(src, dst)
    rate = mid * (1 - p["fx_margin"])
    send = receive / rate + fee
    ideal = receive / mid
    return {"provider_id": p["id"], "provider": p["name"], "eta": p["eta"], "send_amount": round(send, 2),
            "send_currency": src, "fee": round(fee, 2), "rate": round(rate, 4), "mid_rate": round(mid, 4),
            "receive_amount": round(receive, 2), "receive_currency": dst,
            "total_cost_pct": round((send - ideal) / send * 100, 2)}


def options(receive: float, src: str, dst: str) -> list[dict]:
    """Every provider, cheapest for the family first."""
    return sorted((quote_to_receive(receive, src, dst, p["id"]) for p in sandbox.PROVIDERS),
                  key=lambda q: q["send_amount"])


# ---- requests --------------------------------------------------------------------------------------------

def _family(db: Session, user: User, payee_id: int) -> Payee:
    payee = db.get(Payee, payee_id)
    if not is_family(payee, user.id):
        raise FundsError("Choose a family member from your saved recipients")
    return payee


def family_members(db: Session, user: User) -> list[dict]:
    rows = db.scalars(select(Payee).where(Payee.owner_user_id == user.id).order_by(Payee.id)).all()
    return [{"id": p.id, "name": p.name, "relationship": p.relationship, "country": p.country,
             "currency": p.currency} for p in rows if is_family(p, user.id)]


def view(db: Session, r: FundRequest) -> dict:
    payee = db.get(Payee, r.payee_id)
    out = {"id": r.id, "status": r.status, "amount": r.amount, "currency": r.currency, "reason": r.reason,
           "send_currency": r.send_currency,
           "family": {"id": payee.id, "name": payee.name, "relationship": payee.relationship} if payee else None,
           "created_at": r.created_at.isoformat() if r.created_at else None,
           "received_at": r.received_at.isoformat() if r.received_at else None, "transaction_id": r.transaction_id}
    if r.status == "RECEIVED":
        out["received_via"] = {"provider_id": r.provider_id, "provider": sandbox.PROVIDER_BY_ID[r.provider_id]["name"],
                               "send_amount": r.send_amount, "fee": r.fee, "rate": r.rate}
    else:
        out["options"] = options(r.amount, r.send_currency, r.currency)
    return out


def create(db: Session, user: User, *, payee_id: int, amount: float, currency: str | None = None,
           reason: str | None = None) -> FundRequest:
    payee = _family(db, user, payee_id)
    currency = sandbox.check_currency(currency or user.study_currency)
    send_currency = sandbox.check_currency(payee.currency or user.home_currency)
    if send_currency == currency:
        raise FundsError("Your family's currency is the same as the one you need; no exchange is involved")
    r = FundRequest(user_id=user.id, payee_id=payee.id, amount=round(amount, 2), currency=currency,
                    send_currency=send_currency, reason=(reason or "").strip()[:200] or None, status="REQUESTED")
    db.add(r)
    db.flush()
    best = options(r.amount, send_currency, currency)[0]
    audit.record(db, user_id=user.id, actor="STUDENT", event="FUNDS_REQUESTED", tier="T0",
                 details={"request_id": r.id, "family": payee.name, "amount": r.amount, "currency": currency,
                          "best_provider": best["provider_id"], "best_send_amount": best["send_amount"]})
    notify(db, user.id, kind="FUNDS_REQUESTED", title=f"Request sent to {payee.name}",
           body=(f"You asked for {r.amount:,.0f} {currency}. Cheapest for your family: {best['provider']}, "
                 f"{best['send_amount']:,.0f} {send_currency}."),
           data={"key": f"funds:{r.id}", "request_id": r.id})
    return r


def receive(db: Session, user: User, request_id: int, provider_id: str) -> FundRequest:
    """Sandbox: the family sent the money through `provider_id`; it arrives in the study-currency wallet."""
    r = db.get(FundRequest, request_id)
    if r is None or r.user_id != user.id:
        raise FundsError("Request not found")
    if r.status != "REQUESTED":
        raise FundsError(f"This request is already {r.status.lower()}")
    if provider_id not in sandbox.PROVIDER_BY_ID:
        raise FundsError("Unknown provider")
    payee = db.get(Payee, r.payee_id)
    q = quote_to_receive(r.amount, r.send_currency, r.currency, provider_id)
    tx = Transaction(user_id=user.id, kind="REMITTANCE_IN", direction="IN", amount=r.amount, currency=r.currency,
                     amount_usd=sandbox.to_usd(r.amount, r.currency), payee_id=payee.id, counterparty=payee.name,
                     counterparty_account=payee.account_ref, channel="BANK_TRANSFER", provider=q["provider"],
                     fee=q["fee"], fx_rate=q["rate"],
                     memo=f"From {payee.relationship}: {q['send_amount']:,.2f} {r.send_currency} via {q['provider']}",
                     initiated_by="SANDBOX", status="PENDING", tier="T0")
    db.add(tx)
    db.flush()
    sandbox.settle(db, tx)
    r.status, r.provider_id, r.send_amount, r.fee, r.rate = "RECEIVED", provider_id, q["send_amount"], q["fee"], q["rate"]
    r.transaction_id, r.received_at = tx.id, datetime.now(timezone.utc)
    audit.record(db, user_id=user.id, actor="SYSTEM", event="FUNDS_RECEIVED", tier="T0",
                 details={"request_id": r.id, "transaction_id": tx.id, "family": payee.name, "amount": r.amount,
                          "currency": r.currency, "provider": provider_id, "send_amount": q["send_amount"],
                          "send_currency": r.send_currency})
    notify(db, user.id, kind="FUNDS_RECEIVED", title=f"Money received from {payee.name}",
           body=f"{r.amount:,.0f} {r.currency} arrived via {q['provider']}.",
           data={"key": f"funds-in:{r.id}", "request_id": r.id, "transaction_id": tx.id})
    return r


def cancel(db: Session, user: User, request_id: int) -> FundRequest:
    r = db.get(FundRequest, request_id)
    if r is None or r.user_id != user.id:
        raise FundsError("Request not found")
    if r.status != "REQUESTED":
        raise FundsError(f"This request is already {r.status.lower()}")
    r.status = "CANCELLED"
    audit.record(db, user_id=user.id, actor="STUDENT", event="FUNDS_REQUEST_CANCELLED", tier="T0",
                 details={"request_id": r.id})
    return r

