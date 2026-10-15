"""
Behavioural risk features for cross-border student payments.

Every feature here can be computed from data the platform actually has at payment time
(the payment itself, the payee registry and the student's own history). The same list is
used by ml/generate_data.py, ml/train_hybrid.py and the live risk engine.
"""

import math

FEATURE_NAMES = [
    "amount_usd",
    "log_amount",
    "amount_to_avg",              # payment / student's average outgoing payment (90d)
    "hour",
    "is_night",                   # 00:00-05:59 local time
    "kind_tuition",
    "kind_remit_out",
    "kind_card",
    "payee_new",                  # no completed payment to this payee before
    "payee_verified",             # payee is in the verified institution registry
    "payee_individual",
    "country_mismatch",           # tuition payee outside study country / remittance outside home country
    "risky_channel",              # crypto, gift card, e-wallet to a private person
    "velocity_24h",               # outgoing payments in the last 24h
    "outflow_24h_usd",
    "account_age_days",
    "inbound_new_sender_72h_usd",  # money received from first-time senders in the last 72h
    "passthrough_ratio",          # (this payment + 24h outflow) / recent inbound from new senders
    "pressure_flags",             # urgency / discount / threat language in the request (0-3)
    "name_account_mismatch",      # payee name looks like a registered institution but the account differs
]

# Plain-language templates for the top contributing features (used in explanations).
REASON_TEMPLATES = {
    "amount_to_avg": lambda f: f"Amount is {f['amount_to_avg']:.1f}x your usual payment",
    "is_night": lambda f: "Made at an unusual hour (between midnight and 6 am)",
    "payee_new": lambda f: "First payment to this payee",
    "payee_verified": lambda f: ("Payee is a verified institution account" if f["payee_verified"]
                                 else "Payee is not in the verified institution registry"),
    "payee_individual": lambda f: "Money goes to a private person, not an institution",
    "country_mismatch": lambda f: "Payee country does not match where this payment should go",
    "risky_channel": lambda f: "Uses a hard-to-reverse channel (crypto, gift card or e-wallet to a person)",
    "velocity_24h": lambda f: f"{int(f['velocity_24h'])} outgoing payments in the last 24 hours",
    "outflow_24h_usd": lambda f: f"${f['outflow_24h_usd']:,.0f} already sent out in the last 24 hours",
    "account_age_days": lambda f: f"Account is only {int(f['account_age_days'])} days old",
    "inbound_new_sender_72h_usd": lambda f: f"${f['inbound_new_sender_72h_usd']:,.0f} recently received from first-time senders",
    "passthrough_ratio": lambda f: "Money received from a stranger is being forwarded on (money-mule pattern)",
    "pressure_flags": lambda f: "Request uses pressure tactics (urgency, discount or threats)",
    "name_account_mismatch": lambda f: "Payee claims to be a registered institution but the account does not match the official one",
    "amount_usd": lambda f: f"Large amount (${f['amount_usd']:,.0f})",
    "log_amount": lambda f: f"Large amount (${f['amount_usd']:,.0f})",
    "kind_tuition": lambda f: "Tuition payment",
    "kind_remit_out": lambda f: "Outgoing international transfer",
    "kind_card": lambda f: "Card payment",
    "hour": lambda f: f"Made at {int(f['hour']):02d}:00",
}


def build_feature_vector(values: dict) -> list[float]:
    """Fill derived fields and return values in FEATURE_NAMES order."""
    v = dict(values)
    v["log_amount"] = math.log1p(max(v.get("amount_usd", 0.0), 0.0))
    v["is_night"] = 1.0 if 0 <= v.get("hour", 12) < 6 else 0.0
    return [float(v.get(name, 0.0)) for name in FEATURE_NAMES]
