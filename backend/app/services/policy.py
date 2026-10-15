"""
Permission tiers: what the agent may do on its own.

T0  READ     look-ups, quotes, checks                      -> runs immediately
T1  AUTO     small payment to a known payee, low risk       -> agent executes, student is notified
T2  CONFIRM  new payee, medium risk, large amount, tuition  -> waits for the student to confirm in the app
T3  BLOCK    high risk, impersonation, mule pattern, ...    -> refused, with reasons

The LLM never decides the tier. It only proposes an action; this module decides, using the
risk engine and hard rules. Confirmation is only possible through an authenticated UI call,
never through chat text, so instructions hidden in an invoice or message cannot approve a payment.
"""

from dataclasses import dataclass, field

from app.core.config import settings


@dataclass
class Decision:
    tier: str
    decision: str  # READ | AUTO | CONFIRM | BLOCK
    rules: list[str] = field(default_factory=list)

    def as_dict(self):
        return {"tier": self.tier, "decision": self.decision, "rules": self.rules}


READ_ONLY = Decision("T0", "READ", ["Read-only action"])


def decide_payment(*, kind: str, risk: dict, features: dict, verification_status: str | None,
                   amount_usd: float, auto_used_today_usd: float) -> Decision:
    block, confirm = [], []

    if verification_status == "IMPERSONATION":
        block.append("Payee impersonates a registered institution (account does not match the official one)")
    if kind == "TUITION" and verification_status != "VERIFIED":
        block.append("Tuition can only be paid to an official account in the verified institution registry")
    if features.get("risky_channel") and features.get("payee_individual"):
        block.append("Hard-to-reverse channel (crypto / gift card / e-wallet) to a private person")
    if (features.get("passthrough_ratio", 0) >= 0.6 and features.get("payee_new")
            and features.get("inbound_new_sender_72h_usd", 0) > 0):
        block.append("Money-mule pattern: forwarding money just received from a first-time sender")
    if risk["level"] == "HIGH":
        block.append(f"Hybrid model risk is HIGH ({risk['score']:.0%})")
    if block:
        return Decision("T3", "BLOCK", block)

    if risk["level"] == "MEDIUM":
        confirm.append(f"Hybrid model risk is MEDIUM ({risk['score']:.0%})")
    if kind == "TUITION":
        confirm.append("Tuition payments always need your confirmation")
    if features.get("payee_new"):
        confirm.append("First payment to this payee")
    if amount_usd > settings.AUTO_EXECUTE_LIMIT_USD:
        confirm.append(f"Above the ${settings.AUTO_EXECUTE_LIMIT_USD:,.0f} auto-execute limit")
    elif auto_used_today_usd + amount_usd > settings.AUTO_EXECUTE_DAILY_LIMIT_USD:
        confirm.append(f"Would exceed the ${settings.AUTO_EXECUTE_DAILY_LIMIT_USD:,.0f} daily auto-execute limit")
    if confirm:
        return Decision("T2", "CONFIRM", confirm)

    return Decision("T1", "AUTO", ["Known payee, low risk, within auto-execute limits"])
