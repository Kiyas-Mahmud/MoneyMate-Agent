"""Live risk engine: builds behavioural features from the database and scores them with the hybrid model."""

from datetime import datetime, timedelta, timezone
from functools import lru_cache

import joblib
import numpy as np
import xgboost as xgb
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Payee, Transaction, User
from app.services.risk.features import FEATURE_NAMES, REASON_TEMPLATES, build_feature_vector
from app.services.risk.hybrid import base_scores

RISKY_CHANNELS = {"CRYPTO", "GIFT_CARD", "EWALLET_P2P"}
BINARY_REASON_WHEN_ONE = {"is_night", "payee_new", "payee_individual", "country_mismatch", "risky_channel",
                          "name_account_mismatch"}
SKIP_REASONS = {"hour", "kind_tuition", "kind_remit_out", "kind_card", "log_amount"}
# A feature is only worth mentioning as a risk signal when its value is actually unusual
RISK_WHEN = {
    "amount_to_avg": lambda v: v >= 3,
    "amount_usd": lambda v: v >= 1000,
    "velocity_24h": lambda v: v >= 3,
    "outflow_24h_usd": lambda v: v >= 500,
    "account_age_days": lambda v: v < 60,
    "inbound_new_sender_72h_usd": lambda v: v > 0,
    "passthrough_ratio": lambda v: v >= 0.5,
    "pressure_flags": lambda v: v >= 1,
    "payee_verified": lambda v: v == 0,
}
PROTECTIVE_WHEN = {
    "payee_verified": lambda v: v == 1,
    "amount_to_avg": lambda v: v <= 1.5,
    "payee_new": lambda v: v == 0,
}
PROTECTIVE_TEXT = {"payee_new": "You have paid this payee successfully before"}


@lru_cache(maxsize=1)
def load_bundle() -> dict:
    return joblib.load(settings.MODEL_BUNDLE_PATH)


def _aware(dt: datetime) -> datetime:
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def build_features(db: Session, user: User, *, kind: str, amount_usd: float, payee: Payee | None,
                   counterparty_account: str | None = None, channel: str = "BANK_TRANSFER",
                   payee_country: str | None = None, pressure_flags: int = 0,
                   name_account_mismatch: bool = False, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    # Payments to third parties only: conversions between the student's own wallets are not outflows
    completed_out = select(Transaction).where(Transaction.user_id == user.id, Transaction.direction == "OUT",
                                              Transaction.status == "COMPLETED", Transaction.kind != "FX")

    avg_90d = db.scalar(select(func.avg(Transaction.amount_usd)).where(
        Transaction.user_id == user.id, Transaction.direction == "OUT", Transaction.status == "COMPLETED",
        Transaction.kind != "FX", Transaction.created_at >= now - timedelta(days=90)))
    recent = db.scalars(completed_out.where(Transaction.created_at >= now - timedelta(hours=24))).all()

    if payee is not None:
        paid_before = db.scalar(select(func.count()).select_from(Transaction).where(
            Transaction.user_id == user.id, Transaction.payee_id == payee.id, Transaction.status == "COMPLETED")) > 0
    else:
        paid_before = bool(counterparty_account) and db.scalar(select(func.count()).select_from(Transaction).where(
            Transaction.user_id == user.id, Transaction.counterparty_account == counterparty_account,
            Transaction.status == "COMPLETED")) > 0

    # Money received from senders this student has never received from before (mule detection)
    from app.services.funds import is_family

    inbound_new = 0.0
    for tx in db.scalars(select(Transaction).where(
            Transaction.user_id == user.id, Transaction.direction == "IN", Transaction.status == "COMPLETED",
            Transaction.created_at >= now - timedelta(hours=72))).all():
        if tx.payee_id and is_family(db.get(Payee, tx.payee_id), user.id):
            continue  # money a saved family member sent on request is not from a stranger
        earlier = db.scalar(select(func.count()).select_from(Transaction).where(
            Transaction.user_id == user.id, Transaction.direction == "IN", Transaction.status == "COMPLETED",
            Transaction.counterparty == tx.counterparty, Transaction.created_at < tx.created_at - timedelta(days=3)))
        if not earlier:
            inbound_new += tx.amount_usd

    outflow_24h = sum(t.amount_usd for t in recent)
    country = payee.country if payee is not None else payee_country
    if kind == "TUITION":
        mismatch = bool(country) and country != user.study_country
    elif kind == "REMITTANCE_OUT":  # family at home or people where the student lives are expected
        mismatch = bool(country) and country not in (user.home_country, user.study_country)
    else:
        mismatch = False
    individual = payee is None or payee.kind == "INDIVIDUAL"

    values = {
        "amount_usd": amount_usd,
        "amount_to_avg": amount_usd / avg_90d if avg_90d else 1.0,
        "hour": now.astimezone().hour,
        "kind_tuition": int(kind == "TUITION"),
        "kind_remit_out": int(kind == "REMITTANCE_OUT"),
        "kind_card": int(kind == "CARD"),
        "payee_new": int(not paid_before),
        "payee_verified": int(payee is not None and payee.verified and payee.owner_user_id is None),
        "payee_individual": int(individual),
        "country_mismatch": int(mismatch),
        "risky_channel": int(channel in RISKY_CHANNELS),
        "velocity_24h": len(recent),
        "outflow_24h_usd": outflow_24h,
        "account_age_days": max((now - _aware(user.created_at)).days, 0) if user.created_at else 365,
        "inbound_new_sender_72h_usd": inbound_new,
        "passthrough_ratio": min((amount_usd + outflow_24h) / inbound_new, 5.0) if inbound_new > 0 else 0.0,
        "pressure_flags": min(int(pressure_flags), 3),
        "name_account_mismatch": int(name_account_mismatch),
    }
    vec = build_feature_vector(values)
    return dict(zip(FEATURE_NAMES, vec))


def score(features: dict) -> dict:
    b = load_bundle()
    X = np.array([[features[n] for n in b["feature_names"]]], dtype=float)
    S = base_scores(b["models"], X, b["legit_errors"])
    p = float(b["meta"].predict_proba(S)[0, 1])
    th = b["thresholds"]
    level = "HIGH" if p >= th["high"] else ("MEDIUM" if p >= th["medium"] else "LOW")

    # TreeSHAP contributions from the XGBoost base learner explain which features drove the score
    contribs = b["models"]["xgboost"].get_booster().predict(xgb.DMatrix(X), pred_contribs=True)[0][:-1]
    order = np.argsort(-np.abs(contribs))
    reasons, protective = [], []
    min_impact = 0.5 if level == "LOW" else 0.15  # keep low-risk explanations short
    for i in order:
        name, c, val = b["feature_names"][i], float(contribs[i]), features[b["feature_names"][i]]
        if name in SKIP_REASONS or abs(c) < 0.15:
            continue
        if c > 0 and c >= min_impact:
            unusual = (val == 1) if name in BINARY_REASON_WHEN_ONE else RISK_WHEN.get(name, lambda v: True)(val)
            if unusual and name not in {r["feature"] for r in reasons}:
                reasons.append({"feature": name, "text": REASON_TEMPLATES[name](features), "impact": round(c, 3)})
        elif c < 0 and PROTECTIVE_WHEN.get(name, lambda v: False)(val):
            text = PROTECTIVE_TEXT.get(name) or REASON_TEMPLATES[name](features)
            if text not in protective:
                protective.append(text)
    return {
        "score": round(p, 4),
        "level": level,
        "thresholds": th,
        "model_scores": {n: round(float(s), 4) for n, s in zip(b["base_model_names"], S[0])},
        "reasons": reasons[:4],
        "protective_factors": protective[:3],
        "model_version": b["version"],
    }
