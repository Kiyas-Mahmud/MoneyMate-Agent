"""
Payment verification with the student's registered Android phone.

Enrolment: the app creates a P-256 (ECDSA) key pair in the Android Keystore, hardware-backed (StrongBox when
available, otherwise the TEE), usable only after BiometricPrompt (fingerprint / face unlock), and registers only
the public key here (X.509 SubjectPublicKeyInfo, base64). Ed25519 keys are also accepted for test clients.
Verification: for each payment the server issues a one-time challenge; the phone asks for the biometric, signs
the challenge (SHA256withECDSA) and sends the signature. The server checks it with the stored public key. A
stolen password or a message to the agent cannot produce this signature.
"""

import base64
import secrets
from datetime import datetime, timezone

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import load_der_public_key
from sqlalchemy.orm import Session

from app.models import AgentAction, Device, User

KEY_TYPES = ("p256", "ed25519")


class VerificationError(ValueError):
    pass


def challenge_text(action: AgentAction) -> str:
    return f"moneymate-verify:{action.id}:{action.verification_nonce}"


def new_nonce() -> str:
    return secrets.token_urlsafe(24)


def _load_key(key_type: str, public_key_b64: str):
    raw = base64.b64decode(public_key_b64, validate=True)
    if key_type == "ed25519":
        return Ed25519PublicKey.from_public_bytes(raw)
    key = load_der_public_key(raw)
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("not a P-256 key")
    return key


def register(db: Session, user: User, name: str, public_key_b64: str, push_token: str | None,
             key_type: str = "p256") -> Device:
    if key_type not in KEY_TYPES:
        raise VerificationError(f"key_type must be one of {', '.join(KEY_TYPES)}")
    try:
        _load_key(key_type, public_key_b64)
    except Exception:
        raise VerificationError("public_key must be a base64 P-256 SubjectPublicKeyInfo (Android Keystore "
                                "getPublicKey().getEncoded()) or, with key_type=ed25519, 32 raw bytes")
    d = Device(user_id=user.id, name=name[:80], key_type=key_type, public_key=public_key_b64, push_token=push_token)
    db.add(d)
    db.flush()
    return d


def check_signature(db: Session, user: User, action: AgentAction, device_id: int, signature_b64: str) -> Device:
    device = db.get(Device, device_id)
    if device is None or device.user_id != user.id:
        raise VerificationError("Unknown device")
    if not action.verification_nonce:
        raise VerificationError("No open verification challenge for this payment")
    message = challenge_text(action).encode("utf-8")
    try:
        key = _load_key(device.key_type, device.public_key)
        signature = base64.b64decode(signature_b64)
        if device.key_type == "ed25519":
            key.verify(signature, message)
        else:
            key.verify(signature, message, ec.ECDSA(hashes.SHA256()))  # DER signature from SHA256withECDSA
    except (InvalidSignature, ValueError, TypeError):
        raise VerificationError("Verification failed: the signature does not match this payment")
    device.last_used_at = datetime.now(timezone.utc)
    return device
