"""
Payment verification with the student's registered phone.

Enrolment: the app creates an Ed25519 key pair in the phone's secure hardware (Secure Enclave / Android
Keystore), protected by Face ID / fingerprint, and registers only the public key here.
Verification: for each payment the server issues a one-time challenge; the phone asks for Face ID, signs
the challenge and sends the signature. The server checks it with the stored public key. A stolen password
or a message to the agent cannot produce this signature.
"""

import base64
import secrets
from datetime import datetime, timezone

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from sqlalchemy.orm import Session

from app.models import AgentAction, Device, User


class VerificationError(ValueError):
    pass


def challenge_text(action: AgentAction) -> str:
    return f"moneymate-verify:{action.id}:{action.verification_nonce}"


def new_nonce() -> str:
    return secrets.token_urlsafe(24)


def register(db: Session, user: User, name: str, public_key_b64: str, push_token: str | None) -> Device:
    try:
        raw = base64.b64decode(public_key_b64, validate=True)
        Ed25519PublicKey.from_public_bytes(raw)
    except Exception:
        raise VerificationError("public_key must be a base64-encoded 32-byte Ed25519 public key")
    d = Device(user_id=user.id, name=name[:80], public_key=public_key_b64, push_token=push_token)
    db.add(d)
    db.flush()
    return d


def check_signature(db: Session, user: User, action: AgentAction, device_id: int, signature_b64: str) -> Device:
    device = db.get(Device, device_id)
    if device is None or device.user_id != user.id:
        raise VerificationError("Unknown device")
    if not action.verification_nonce:
        raise VerificationError("No open verification challenge for this payment")
    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(device.public_key))
        key.verify(base64.b64decode(signature_b64), challenge_text(action).encode("utf-8"))
    except (InvalidSignature, ValueError, TypeError):
        raise VerificationError("Verification failed: the signature does not match this payment")
    device.last_used_at = datetime.now(timezone.utc)
    return device
