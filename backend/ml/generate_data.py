"""
Synthetic training data for cross-border student payments.

No public dataset covers international-student tuition and remittance fraud, so we simulate it
from documented fraud typologies (fake tuition agents, impersonation / remittance scams,
money-mule pass-through, account takeover) plus normal student behaviour. Distributions overlap
on purpose and 1% of labels are flipped, so the task is not trivially separable.

This data is a stand-in until partner data (banks, universities) is available. The hybrid
architecture itself was validated on the real IEEE-CIS benchmark (see ml/research/).

Usage:  python -m ml.generate_data --rows 80000
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from app.services.risk.features import FEATURE_NAMES, build_feature_vector

OUT = Path(__file__).resolve().parent / "data" / "student_payments.csv"


def _hour(rng, night_p):
    if rng.random() < night_p:
        return int(rng.integers(0, 6))
    return int(np.clip(rng.normal(15, 3.5), 6, 23))


def _base(rng):
    return {
        "kind_tuition": 0, "kind_remit_out": 0, "kind_card": 0,
        "payee_new": 0, "payee_verified": 0, "payee_individual": 0,
        "country_mismatch": 0, "risky_channel": 0,
        "velocity_24h": int(rng.poisson(1.0)),
        "account_age_days": float(rng.uniform(20, 1200)),
        "inbound_new_sender_72h_usd": 0.0, "passthrough_ratio": 0.0,
        "pressure_flags": 0, "name_account_mismatch": 0,
    }


def legit(rng):
    r = _base(rng)
    t = rng.choice(["card", "tuition", "remit", "local", "unusual", "income"],
                   p=[0.44, 0.08, 0.20, 0.12, 0.08, 0.08])
    if t == "card":
        r.update(kind_card=1, amount_usd=float(np.clip(rng.lognormal(3.0, 0.9), 2, 600)),
                 payee_new=int(rng.random() < 0.3), amount_to_avg=float(rng.lognormal(0, 0.6)),
                 hour=_hour(rng, 0.06), risky_channel=int(rng.random() < 0.01))
    elif t == "tuition":
        r.update(kind_tuition=1, amount_usd=float(rng.uniform(1500, 12000)),
                 payee_new=int(rng.random() < 0.35), payee_verified=int(rng.random() < 0.97),
                 country_mismatch=int(rng.random() < 0.02), amount_to_avg=float(rng.uniform(6, 70)),
                 hour=_hour(rng, 0.04), pressure_flags=int(rng.random() < 0.06))
    elif t == "remit":
        r.update(kind_remit_out=1, payee_individual=1, amount_usd=float(np.clip(rng.lognormal(5.0, 0.8), 20, 2500)),
                 payee_new=int(rng.random() < 0.12), country_mismatch=int(rng.random() < 0.05),
                 amount_to_avg=float(rng.lognormal(0.3, 0.7)), hour=_hour(rng, 0.08),
                 risky_channel=int(rng.random() < 0.02), pressure_flags=int(rng.random() < 0.03))
    elif t == "local":  # rent, phone bill, shops paid by transfer
        r.update(amount_usd=float(rng.uniform(80, 1600)), payee_new=int(rng.random() < 0.25),
                 payee_individual=int(rng.random() < 0.5), country_mismatch=int(rng.random() < 0.08),
                 amount_to_avg=float(rng.lognormal(0.8, 0.7)), hour=_hour(rng, 0.05))
    elif t == "unusual":  # genuine but odd: late-night, big, new payee, busy day
        r.update(kind_card=int(rng.random() < 0.4), kind_remit_out=int(rng.random() < 0.3),
                 amount_usd=float(rng.uniform(200, 4000)), payee_new=int(rng.random() < 0.6),
                 payee_individual=int(rng.random() < 0.4), amount_to_avg=float(rng.uniform(2, 15)),
                 hour=_hour(rng, 0.35), velocity_24h=int(rng.poisson(3)),
                 country_mismatch=int(rng.random() < 0.15), risky_channel=int(rng.random() < 0.05),
                 pressure_flags=int(rng.random() < 0.08))
    else:  # scholarship / part-time salary from a new sender, then normal spending
        inbound = float(rng.uniform(300, 4000))
        amt = float(rng.uniform(20, 900))
        r.update(kind_card=int(rng.random() < 0.6), amount_usd=amt, inbound_new_sender_72h_usd=inbound,
                 passthrough_ratio=float(min(amt * rng.uniform(1, 2.5) / inbound, 0.85)),
                 payee_new=int(rng.random() < 0.35), amount_to_avg=float(rng.lognormal(0.2, 0.6)),
                 hour=_hour(rng, 0.07))
    r["outflow_24h_usd"] = float(r["velocity_24h"] * rng.lognormal(3.5, 0.9))
    return r


def fraud(rng):
    r = _base(rng)
    t = rng.choice(["fake_tuition", "scam_remit", "mule", "takeover", "stealth"],
                   p=[0.25, 0.25, 0.20, 0.20, 0.10])
    if t == "fake_tuition":
        r.update(kind_tuition=1, amount_usd=float(rng.uniform(1200, 15000)), payee_new=1,
                 payee_verified=int(rng.random() < 0.03), payee_individual=int(rng.random() < 0.6),
                 country_mismatch=int(rng.random() < 0.6), amount_to_avg=float(rng.uniform(6, 80)),
                 pressure_flags=int(rng.choice([0, 1, 2, 3], p=[0.25, 0.35, 0.25, 0.15])),
                 name_account_mismatch=int(rng.random() < 0.35), risky_channel=int(rng.random() < 0.25),
                 hour=_hour(rng, 0.1))
    elif t == "scam_remit":  # "visa fee", fake officer, romance / family-emergency impersonation
        r.update(kind_remit_out=1, payee_individual=1, amount_usd=float(rng.uniform(250, 6000)),
                 payee_new=int(rng.random() < 0.9), country_mismatch=int(rng.random() < 0.7),
                 amount_to_avg=float(rng.uniform(2.5, 35)),
                 pressure_flags=int(rng.choice([0, 1, 2, 3], p=[0.35, 0.3, 0.2, 0.15])),
                 risky_channel=int(rng.random() < 0.3), hour=_hour(rng, 0.2))
    elif t == "mule":
        inbound = float(rng.uniform(500, 9000))
        amt = float(inbound * rng.uniform(0.3, 1.0))
        r.update(kind_remit_out=int(rng.random() < 0.6), amount_usd=amt, inbound_new_sender_72h_usd=inbound,
                 passthrough_ratio=float(rng.uniform(0.6, 1.3)), payee_new=int(rng.random() < 0.85),
                 payee_individual=int(rng.random() < 0.7), country_mismatch=int(rng.random() < 0.5),
                 velocity_24h=int(rng.integers(1, 9)), account_age_days=float(rng.uniform(5, 250)),
                 amount_to_avg=float(rng.uniform(2, 30)), risky_channel=int(rng.random() < 0.25),
                 hour=_hour(rng, 0.15))
    elif t == "takeover":
        r.update(kind_card=int(rng.random() < 0.5), kind_remit_out=int(rng.random() < 0.4),
                 amount_usd=float(rng.uniform(150, 5000)), payee_new=int(rng.random() < 0.9),
                 payee_individual=int(rng.random() < 0.5), amount_to_avg=float(rng.uniform(4, 50)),
                 velocity_24h=int(rng.integers(3, 15)), country_mismatch=int(rng.random() < 0.4),
                 risky_channel=int(rng.random() < 0.2), hour=_hour(rng, 0.55))
    else:  # low-signal fraud that looks almost normal
        r.update(kind_card=int(rng.random() < 0.5), amount_usd=float(np.clip(rng.lognormal(4.5, 1.0), 10, 3000)),
                 payee_new=int(rng.random() < 0.5), payee_individual=int(rng.random() < 0.4),
                 amount_to_avg=float(rng.lognormal(0.6, 0.8)), hour=_hour(rng, 0.15),
                 country_mismatch=int(rng.random() < 0.2))
    r["outflow_24h_usd"] = float(r["velocity_24h"] * rng.lognormal(5.0, 1.0))
    return r


def generate(rows: int, fraud_rate: float = 0.07, seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    labels = (rng.random(rows) < fraud_rate).astype(int)
    data = [build_feature_vector(fraud(rng) if y else legit(rng)) for y in labels]
    df = pd.DataFrame(data, columns=FEATURE_NAMES)
    flip = rng.random(rows) < 0.01
    df["is_fraud"] = np.where(flip, 1 - labels, labels)
    return df


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=80000)
    args = ap.parse_args()
    df = generate(args.rows)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT, index=False)
    print(f"wrote {len(df)} rows ({df.is_fraud.mean():.2%} fraud) -> {OUT}")
