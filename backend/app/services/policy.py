"""
Permission tiers: what the agent may do on its own.

T0  READ    look-ups, quotes, checks, planning           -> runs immediately
T2  VERIFY  every movement of money (payment, transfer,  -> the agent prepares it and the student must
            conversion, scheduled payment)                  verify on their phone (fingerprint / face)
T3  BLOCK   high risk, impersonation, mule pattern, ...  -> refused, with reasons

There is deliberately no auto-execute tier: the agent never moves money without the student's
verification. The LLM never decides the tier. It only proposes an action; this module decides, using
the risk engine and hard rules. Verification is a signed challenge from the student's registered device
(see devices.py), never chat text, so instructions hidden in an invoice or message cannot approve a payment.
"""

from dataclasses import dataclass, field

VERIFY_RULE = "Every payment needs your verification. The agent can't move money on its own."


@dataclass
class Decision:
    tier: str
    decision: str  # READ | VERIFY | BLOCK
    rules: list[str] = field(default_factory=list)

    def as_dict(self):
        return {"tier": self.tier, "decision": self.decision, "rules": self.rules}


READ_ONLY = Decision("T0", "READ", ["Read-only action"])


def decide_payment(*, kind: str, risk: dict, features: dict, verification_status: str | None) -> Decision:
    block = []
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

    # Not blocked: prepare it and ask the student to verify. Extra notes explain what to look at.
    notes = [VERIFY_RULE]
    if risk["level"] == "MEDIUM":
        notes.append(f"Check carefully: hybrid model risk is MEDIUM ({risk['score']:.0%})")
    if features.get("payee_new"):
        notes.append("First payment to this payee")
    return Decision("T2", "VERIFY", notes)


def decide_conversion() -> Decision:
    """Moving money between the student's own wallets: no third party, but still verified."""
    return Decision("T2", "VERIFY", [VERIFY_RULE, "Conversion between your own wallets"])
