"""
Sandbox money layer. Balances and remittance providers are simulated; nothing here touches a real
bank. Mid-market FX rates are live (ExchangeRate-API open access, refreshed hourly) with a dated
snapshot as fallback. In production this module is replaced by licensed partner APIs.
"""

import logging
import threading
import time
from datetime import datetime, timezone

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Transaction, Wallet

log = logging.getLogger(__name__)

# Fallback mid-market rates: units of currency per 1 USD
SANDBOX_RATES = {"USD": 1.0, "BDT": 122.0, "CNY": 7.12, "CAD": 1.38, "GBP": 0.75, "MYR": 4.22, "EUR": 0.86}
SANDBOX_AS_OF = "2026-10-15 (sandbox snapshot)"
SUPPORTED = tuple(SANDBOX_RATES)

_fx = {"rates": None, "as_of": None, "fetched_at": 0.0, "failed_at": 0.0}
_fx_lock = threading.Lock()
RETRY_AFTER_FAILURE_S = 300


def _fetch_live() -> tuple[dict, str]:
    r = httpx.get(settings.FX_API_URL, timeout=4.0)
    r.raise_for_status()
    data = r.json()
    if data.get("result") != "success":
        raise ValueError(f"FX API returned {data.get('result')}")
    live = {c: float(data["rates"][c]) for c in SUPPORTED}
    return live, data.get("time_last_update_utc", "")


def rates_info() -> dict:
    """Current mid-market rates (per 1 USD) with their source and timestamp."""
    now = time.monotonic()
    if settings.FX_LIVE:
        with _fx_lock:
            fresh = _fx["rates"] and now - _fx["fetched_at"] < settings.FX_CACHE_SECONDS
            may_retry = now - _fx["failed_at"] > RETRY_AFTER_FAILURE_S or not _fx["failed_at"]
            if not fresh and may_retry:
                try:
                    _fx["rates"], _fx["as_of"] = _fetch_live()
                    _fx["fetched_at"] = now
                except Exception as e:  # network down, API changed, missing currency -> fall back
                    _fx["failed_at"] = now
                    log.warning("Live FX unavailable, using snapshot or last good rates: %s", e)
            if _fx["rates"]:
                return {"rates": dict(_fx["rates"]), "as_of": _fx["as_of"],
                        "source": "live mid-market rates by ExchangeRate-API (exchangerate-api.com)"}
    return {"rates": dict(SANDBOX_RATES), "as_of": SANDBOX_AS_OF, "source": "sandbox snapshot (live rates unavailable)"}


def usd_rates() -> dict:
    return rates_info()["rates"]

# Fictional providers modelled on typical market pricing: flat fee (USD) + FX margin over mid-market
PROVIDERS = [
    {"id": "bank_wire", "name": "Traditional bank wire", "fee_usd": 25.0, "fx_margin": 0.030, "eta": "2-4 days"},
    {"id": "quicksend", "name": "QuickSend", "fee_usd": 4.99, "fx_margin": 0.018, "eta": "Same day"},
    {"id": "remitlite", "name": "RemitLite", "fee_usd": 2.00, "fx_margin": 0.009, "eta": "Within 1 hour"},
    {"id": "cardxfer", "name": "Card-funded transfer", "fee_usd": 0.0, "fx_margin": 0.035, "eta": "Minutes"},
]
PROVIDER_BY_ID = {p["id"]: p for p in PROVIDERS}


class SandboxError(ValueError):
    pass


def check_currency(code: str) -> str:
    code = (code or "").upper()
    if code not in SUPPORTED:
        raise SandboxError(f"Unsupported currency '{code}'. Supported: {', '.join(SUPPORTED)}")
    return code


def to_usd(amount: float, currency: str) -> float:
    return amount / usd_rates()[check_currency(currency)]


def mid_rate(src: str, dst: str) -> float:
    r = usd_rates()
    return r[check_currency(dst)] / r[check_currency(src)]


def quote(amount: float, src: str, dst: str, provider_id: str = "remitlite") -> dict:
    """Quote for sending `amount` in `src`, received in `dst`. Fee is charged in `src`."""
    p = PROVIDER_BY_ID[provider_id]
    fee_src = p["fee_usd"] * usd_rates()[check_currency(src)]
    rate = mid_rate(src, dst) * (1 - p["fx_margin"])
    received = max(amount - fee_src, 0) * rate
    ideal = amount * mid_rate(src, dst)
    total_cost_pct = (ideal - received) / ideal * 100 if ideal else 0.0
    return {
        "provider_id": p["id"], "provider": p["name"], "eta": p["eta"],
        "send_amount": round(amount, 2), "send_currency": src, "fee": round(fee_src, 2),
        "rate": round(rate, 4), "mid_rate": round(mid_rate(src, dst), 4),
        "receive_amount": round(received, 2), "receive_currency": dst,
        "total_cost_pct": round(total_cost_pct, 2),
    }


def compare(amount: float, src: str, dst: str) -> list[dict]:
    return sorted((quote(amount, src, dst, p["id"]) for p in PROVIDERS), key=lambda q: -q["receive_amount"])


def get_wallet(db: Session, user_id: int, currency: str, create: bool = False) -> Wallet | None:
    w = db.scalar(select(Wallet).where(Wallet.user_id == user_id, Wallet.currency == currency))
    if w is None and create:
        w = Wallet(user_id=user_id, currency=currency, balance=0.0)
        db.add(w)
        db.flush()
    return w


def balances(db: Session, user_id: int) -> list[dict]:
    rows = db.scalars(select(Wallet).where(Wallet.user_id == user_id).order_by(Wallet.currency)).all()
    return [{"currency": w.currency, "balance": round(w.balance, 2),
             "usd_equivalent": round(to_usd(w.balance, w.currency), 2)} for w in rows]


def debit(db: Session, user_id: int, currency: str, amount: float):
    w = get_wallet(db, user_id, currency)
    if w is None or w.balance + 1e-9 < amount:
        have = w.balance if w else 0.0
        raise SandboxError(f"Insufficient {currency} balance: need {amount:,.2f}, have {have:,.2f}")
    w.balance -= amount


def credit(db: Session, user_id: int, currency: str, amount: float):
    get_wallet(db, user_id, currency, create=True).balance += amount


def settle(db: Session, tx: Transaction, debit_currency: str | None = None, debit_amount: float | None = None):
    """Move sandbox money for an approved transaction and mark it completed."""
    if tx.direction == "OUT":
        debit(db, tx.user_id, debit_currency or tx.currency, debit_amount if debit_amount is not None else tx.amount)
    else:
        credit(db, tx.user_id, tx.currency, tx.amount)
    tx.status = "COMPLETED"
    tx.executed_at = datetime.now(timezone.utc)
