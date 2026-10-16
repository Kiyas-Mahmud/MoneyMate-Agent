"""
Audit-log anchoring on a public Ethereum test network.

The audit log is a SHA-256 hash chain, but someone with database access could rewrite the whole chain
consistently. Anchoring closes that gap: the latest entry's hash is written into a blockchain transaction,
which nobody can change afterwards. Verification fetches the transaction from the blockchain and compares it
with the log; a rewritten log no longer matches.

The transaction is a zero-value transfer from the anchor wallet to itself. Its data field holds 44 bytes:
b"MMA1" + entry id (8 bytes, big-endian) + the entry's SHA-256 hash (32 bytes). Only hashes go on-chain, never
personal data. Only test networks are allowed.
"""

import logging
from datetime import datetime, timezone

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models import Anchor, AuditLog
from app.services import audit

log = logging.getLogger(__name__)

MAGIC = b"MMA1"
TEST_CHAINS = {11155111: "Ethereum Sepolia", 17000: "Ethereum Holesky", 80002: "Polygon Amoy",
               84532: "Base Sepolia", 31337: "Local test chain"}


class AnchorError(RuntimeError):
    pass


# ---- payload ---------------------------------------------------------------------------------------------

def payload(entry_id: int, head_hash: str) -> bytes:
    return MAGIC + entry_id.to_bytes(8, "big") + bytes.fromhex(head_hash)


def decode(data: str | bytes) -> tuple[int, str] | None:
    """(entry id, hash) from a transaction's data field, or None if it isn't a MoneyMate anchor."""
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data) if isinstance(data, str) else data
    if len(raw) != 44 or raw[:4] != MAGIC:
        return None
    return int.from_bytes(raw[4:12], "big"), raw[12:].hex()


# ---- blockchain access -----------------------------------------------------------------------------------

class Rpc:
    """Minimal JSON-RPC client that tries each configured endpoint in turn."""

    def __init__(self, urls: list[str], timeout: float = 10.0):
        self.urls, self.timeout = urls, timeout

    def call(self, method: str, params: list):
        last: Exception | None = None
        for url in self.urls:
            try:
                r = httpx.post(url, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                               timeout=self.timeout)
                body = r.json()
                if "error" in body:
                    raise AnchorError(f"{method}: {body['error'].get('message', body['error'])}")
                return body["result"]
            except (httpx.HTTPError, ValueError, KeyError, AnchorError) as e:
                last = e
        raise AnchorError(f"Blockchain unavailable ({last})")


def rpc() -> Rpc:
    """Replaced in tests by a fake chain."""
    return Rpc([u.strip() for u in settings.ANCHOR_RPC_URLS.split(",") if u.strip()])


def _account():
    from eth_account import Account

    if not settings.ANCHOR_PRIVATE_KEY:
        raise AnchorError("No anchor wallet configured")
    return Account.from_key(settings.ANCHOR_PRIVATE_KEY)


def wallet_address() -> str | None:
    try:
        return _account().address
    except Exception:
        return None


def chain_name() -> str:
    return TEST_CHAINS.get(settings.ANCHOR_CHAIN_ID, f"chain {settings.ANCHOR_CHAIN_ID}")


def explorer_tx(tx_hash: str | None) -> str | None:
    return f"{settings.ANCHOR_EXPLORER_URL}/tx/{tx_hash}" if tx_hash else None


def _check_test_chain(client: Rpc):
    if settings.ANCHOR_CHAIN_ID not in TEST_CHAINS:
        raise AnchorError(f"Chain {settings.ANCHOR_CHAIN_ID} is not a test network; anchoring only runs on test networks")
    live = int(client.call("eth_chainId", []), 16)
    if live != settings.ANCHOR_CHAIN_ID:
        raise AnchorError(f"The blockchain endpoint is chain {live}, expected {settings.ANCHOR_CHAIN_ID}")


# ---- anchoring -------------------------------------------------------------------------------------------

def refresh(db: Session, client: Rpc | None = None) -> int:
    """Marks sent anchors CONFIRMED (or FAILED) once their transaction is mined. Returns how many changed."""
    pending = db.scalars(select(Anchor).where(Anchor.status == "SENT")).all()
    if not pending:
        return 0
    client = client or rpc()
    changed = 0
    for a in pending:
        receipt = client.call("eth_getTransactionReceipt", [a.tx_hash])
        if not receipt:
            continue
        if int(receipt.get("status", "0x1"), 16) == 1:
            a.status, a.block_number = "CONFIRMED", int(receipt["blockNumber"], 16)
            a.confirmed_at = datetime.now(timezone.utc)
        else:
            a.status, a.error = "FAILED", "Transaction reverted"
        changed += 1
    db.flush()
    return changed


def run(db: Session, client: Rpc | None = None) -> dict:
    """Anchors the audit chain's latest entry if it isn't anchored yet. Never raises: a failure is reported and
    the next run tries again, so payments never depend on the blockchain."""
    if not settings.ANCHOR_ENABLED:
        return {"status": "disabled", "message": "Anchoring is off (ANCHOR_ENABLED)."}
    try:
        account = _account()
        client = client or rpc()
        _check_test_chain(client)
        refresh(db, client)
        head = db.scalar(select(AuditLog).order_by(AuditLog.id.desc()).limit(1))
        if head is None:
            return {"status": "empty", "message": "The audit log is empty."}
        latest = db.scalar(select(Anchor).where(Anchor.status.in_(("SENT", "CONFIRMED")))
                           .order_by(Anchor.entry_id.desc()).limit(1))
        if latest and latest.entry_id >= head.id:
            return {"status": "up_to_date", "anchor": view(latest)}

        data = "0x" + payload(head.id, head.hash).hex()
        tx = {"from": account.address, "to": account.address, "value": "0x0", "data": data}
        gas = int(int(client.call("eth_estimateGas", [tx]), 16) * 1.2)
        base_fee = int(client.call("eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
        try:
            tip = int(client.call("eth_maxPriorityFeePerGas", []), 16)
        except AnchorError:
            tip = 1_000_000_000
        max_fee = base_fee * 2 + tip
        balance = int(client.call("eth_getBalance", [account.address, "latest"]), 16)
        if balance < gas * max_fee:
            return {"status": "unfunded", "address": account.address,
                    "message": f"The anchor wallet has no test ETH. Fund {account.address} from an "
                               f"{chain_name()} faucet."}
        nonce = int(client.call("eth_getTransactionCount", [account.address, "pending"]), 16)
        signed = account.sign_transaction({
            "type": 2, "chainId": settings.ANCHOR_CHAIN_ID, "nonce": nonce, "to": account.address, "value": 0,
            "data": data, "gas": gas, "maxFeePerGas": max_fee, "maxPriorityFeePerGas": tip})
        raw = signed.raw_transaction if hasattr(signed, "raw_transaction") else signed.rawTransaction
        tx_hash = client.call("eth_sendRawTransaction", ["0x" + bytes(raw).hex()])
        a = Anchor(entry_id=head.id, head_hash=head.hash, chain_id=settings.ANCHOR_CHAIN_ID, tx_hash=tx_hash,
                   status="SENT")
        db.add(a)
        db.flush()
        log.info("Anchored audit entry %s in %s", head.id, tx_hash)
        return {"status": "sent", "anchor": view(a)}
    except Exception as e:  # network, funds, configuration: report and retry next time
        log.warning("Audit anchoring failed: %s", e)
        return {"status": "error", "message": str(e)[:300]}


# ---- verification ----------------------------------------------------------------------------------------

_onchain: dict[str, tuple[str, str]] = {}  # tx hash -> (sender, data); mined transactions never change


def _fetch(client: Rpc, tx_hash: str) -> tuple[str, str] | None:
    if tx_hash not in _onchain:
        tx = client.call("eth_getTransactionByHash", [tx_hash])
        if not tx:
            return None
        _onchain[tx_hash] = (tx["from"].lower(), tx.get("input") or tx.get("data") or "")
    return _onchain[tx_hash]


def verify(db: Session, client: Rpc | None = None) -> dict:
    """Compares every confirmed anchor, as written on the blockchain, with the audit log in the database."""
    anchors = db.scalars(select(Anchor).where(Anchor.status == "CONFIRMED").order_by(Anchor.entry_id)).all()
    out = {"chain": chain_name(), "chain_id": settings.ANCHOR_CHAIN_ID, "wallet": wallet_address(),
           "anchors": len(anchors), "anchored_up_to": anchors[-1].entry_id if anchors else None,
           "latest": view(anchors[-1]) if anchors else None, "checked_on_chain": 0, "mismatches": [],
           "on_chain": "not_anchored" if not anchors else "ok"}
    if not anchors:
        return out
    wallet = (out["wallet"] or "").lower()
    try:
        client = client or rpc()
        for a in anchors:
            entry = db.get(AuditLog, a.entry_id)
            onchain = _fetch(client, a.tx_hash)
            decoded = decode(onchain[1]) if onchain else None
            problem = None
            if onchain is None or decoded is None:
                problem = "transaction not found or not an anchor"
            elif wallet and onchain[0] != wallet:
                problem = "sent by a different wallet"
            elif decoded[0] != a.entry_id:
                problem = "anchors a different entry"
            elif entry is None:
                problem = "anchored entry is missing from the log"
            elif decoded[1] != entry.hash:
                problem = "log entry no longer matches the hash on the blockchain"
            out["checked_on_chain"] += 1
            if problem:
                out["mismatches"].append({"entry_id": a.entry_id, "tx_hash": a.tx_hash, "problem": problem})
    except AnchorError as e:
        out["on_chain"] = "unavailable"
        out["message"] = str(e)[:200]
        return out
    out["on_chain"] = "mismatch" if out["mismatches"] else "ok"
    return out


def full_check(db: Session, client: Rpc | None = None) -> dict:
    """The hash chain itself, plus the blockchain anchors. Valid only if both hold."""
    chain = audit.verify_chain(db)
    anchoring = verify(db, client)
    return {**chain, "valid": chain["valid"] and anchoring["on_chain"] != "mismatch", "anchoring": anchoring}


# ---- views -----------------------------------------------------------------------------------------------

def view(a: Anchor) -> dict:
    return {"entry_id": a.entry_id, "hash": a.head_hash, "chain": TEST_CHAINS.get(a.chain_id, str(a.chain_id)),
            "tx_hash": a.tx_hash, "block_number": a.block_number, "status": a.status,
            "explorer_url": explorer_tx(a.tx_hash),
            "created_at": a.created_at.isoformat() if a.created_at else None}


def covering(db: Session, entry_id: int | None) -> dict | None:
    """The first confirmed anchor that includes audit entry `entry_id` (later hashes cover all earlier entries)."""
    if entry_id is None:
        return None
    a = db.scalar(select(Anchor).where(Anchor.status == "CONFIRMED", Anchor.entry_id >= entry_id)
                  .order_by(Anchor.entry_id).limit(1))
    return view(a) if a else None


def entry_for(db: Session, user_id: int, event: str, key: str, value) -> int | None:
    """The audit entry id for an event, e.g. PAYMENT_VERIFIED with transaction_id = 42."""
    rows = db.scalars(select(AuditLog).where(AuditLog.user_id == user_id, AuditLog.event == event)
                      .order_by(AuditLog.id.desc()).limit(200)).all()
    return next((r.id for r in rows if (r.details or {}).get(key) == value), None)


def status_for(db: Session, user_id: int, event: str, key: str, value) -> dict:
    """Anchor information for a receipt or report: anchored, pending (next run) or none (no audit entry)."""
    entry_id = entry_for(db, user_id, event, key, value)
    if entry_id is None:
        return {"state": "none"}
    a = covering(db, entry_id)
    return {"state": "anchored", **a} if a else {"state": "pending", "chain": chain_name()}
