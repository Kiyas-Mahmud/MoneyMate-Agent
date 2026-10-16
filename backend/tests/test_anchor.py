"""Audit-log anchoring, against a fake Ethereum test chain (no network)."""

import pytest
import rlp
from eth_account import Account
from eth_utils import keccak
from sqlalchemy import select

from app.core.config import settings
from app.core.database import SessionLocal
from app.models import Anchor, AuditLog
from app.services import anchor, audit
from tests.test_scenarios import chat, money_action


class FakeChain:
    """Enough of Ethereum's JSON-RPC for anchoring: accepts signed transactions and mines them on request."""

    def __init__(self, chain_id=11155111, balance=10**18, fail=False):
        self.chain_id, self.balance, self.fail = chain_id, balance, fail
        self.txs: dict[str, dict] = {}
        self.mined: set[str] = set()
        self.sent: list[str] = []

    def call(self, method, params):
        if self.fail:
            raise anchor.AnchorError("Blockchain unavailable (connection refused)")
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "eth_estimateGas":
            return hex(22_000)
        if method == "eth_getBlockByNumber":
            return {"baseFeePerGas": hex(1_000_000_000)}
        if method == "eth_maxPriorityFeePerGas":
            return hex(1_000_000_000)
        if method == "eth_getBalance":
            return hex(self.balance)
        if method == "eth_getTransactionCount":
            return hex(len(self.sent))
        if method == "eth_sendRawTransaction":
            raw = bytes.fromhex(params[0][2:])
            assert raw[0] == 2                                     # EIP-1559 transaction
            fields = rlp.decode(raw[1:])
            tx_hash = "0x" + keccak(raw).hex()
            self.txs[tx_hash] = {"from": Account.recover_transaction(raw), "to": "0x" + fields[5].hex(),
                                 "input": "0x" + fields[7].hex(), "chain_id": int.from_bytes(fields[0], "big")}
            self.sent.append(tx_hash)
            return tx_hash
        if method == "eth_getTransactionReceipt":
            h = params[0]
            return {"status": "0x1", "blockNumber": hex(6_800_000 + self.sent.index(h))} if h in self.mined else None
        if method == "eth_getTransactionByHash":
            return self.txs.get(params[0])
        raise AssertionError(f"unexpected RPC method {method}")

    def mine(self):
        self.mined |= set(self.sent)


def _clear():
    with SessionLocal() as db:
        db.query(Anchor).delete()
        db.commit()


@pytest.fixture(autouse=True)
def _no_leftover_anchors():
    """Fake-chain anchors must not reach later tests, which would look them up on the real network."""
    _clear()
    yield
    _clear()


def _setup(monkeypatch, chain):
    key = Account.create()
    monkeypatch.setattr(settings, "ANCHOR_ENABLED", True)
    monkeypatch.setattr(settings, "ANCHOR_PRIVATE_KEY", key.key.hex())
    monkeypatch.setattr(settings, "ANCHOR_CHAIN_ID", 11155111)
    monkeypatch.setattr(anchor, "rpc", lambda: chain)
    monkeypatch.setattr(anchor, "_onchain", {})
    return key.address


def _run_and_mine(client, auth, chain):
    r = client.post("/api/anchors/run", headers=auth).json()
    chain.mine()
    client.post("/api/anchors/run", headers=auth)   # confirms what was sent
    return r


def test_anchor_writes_the_audit_head_to_the_chain(client, auth, monkeypatch):
    chain = FakeChain()
    wallet = _setup(monkeypatch, chain)
    r = _run_and_mine(client, auth, chain)
    assert r["status"] == "sent"
    tx = chain.txs[chain.sent[0]]
    assert tx["from"] == wallet and tx["to"].lower() == wallet.lower() and tx["chain_id"] == 11155111
    with SessionLocal() as db:
        head = db.scalar(select(AuditLog).order_by(AuditLog.id.desc()).limit(1))
        a = db.scalar(select(Anchor).order_by(Anchor.id.desc()).limit(1))
        assert anchor.decode(tx["input"]) == (a.entry_id, a.head_hash)
        assert a.status == "CONFIRMED" and a.block_number == 6_800_000 and a.head_hash == head.hash
    check = client.get("/api/audit/verify", headers=auth).json()
    assert check["valid"] is True and check["anchoring"]["on_chain"] == "ok"
    assert check["anchoring"]["checked_on_chain"] == 1
    listing = client.get("/api/anchors").json()                       # public, no login
    assert listing["chain"] == "Ethereum Sepolia" and listing["anchors"][0]["tx_hash"] == chain.sent[0]
    assert listing["anchors"][0]["explorer_url"].endswith(chain.sent[0])


def test_nothing_new_means_no_new_transaction(client, auth, monkeypatch):
    chain = FakeChain()
    _setup(monkeypatch, chain)
    _run_and_mine(client, auth, chain)
    assert client.post("/api/anchors/run", headers=auth).json()["status"] == "up_to_date"
    assert len(chain.sent) == 1


def test_a_consistently_rewritten_log_is_caught_by_the_anchor(client, auth, monkeypatch):
    chain = FakeChain()
    _setup(monkeypatch, chain)
    _run_and_mine(client, auth, chain)
    with SessionLocal() as db:
        rows = db.scalars(select(AuditLog).order_by(AuditLog.id)).all()
        saved = [(r.id, r.details, r.prev_hash, r.hash) for r in rows]
        # An insider edits an old entry and recomputes every later hash, so the chain itself still checks out.
        rows[0].details = {**(rows[0].details or {}), "rewritten": True}
        prev = audit.GENESIS
        for r in rows:
            created = r.created_at if r.created_at.tzinfo else r.created_at.replace(tzinfo=__import__("datetime").timezone.utc)
            r.prev_hash = prev
            r.hash = audit._digest(prev, created.isoformat(), r.user_id, r.actor, r.event, r.tier, r.details)
            prev = r.hash
        db.commit()
        try:
            assert audit.verify_chain(db)["valid"] is True               # the old check alone is fooled
            check = client.get("/api/audit/verify", headers=auth).json()
            assert check["valid"] is False and check["anchoring"]["on_chain"] == "mismatch"
            assert "no longer matches" in check["anchoring"]["mismatches"][0]["problem"]
        finally:
            for (rid, details, prev_hash, h), r in zip(saved, rows):
                r.details, r.prev_hash, r.hash = details, prev_hash, h
            db.commit()
    assert client.get("/api/audit/verify", headers=auth).json()["valid"] is True


def test_mainnet_is_refused(client, auth, monkeypatch):
    chain = FakeChain(chain_id=1)
    _setup(monkeypatch, chain)
    monkeypatch.setattr(settings, "ANCHOR_CHAIN_ID", 1)
    r = client.post("/api/anchors/run", headers=auth).json()
    assert r["status"] == "error" and "not a test network" in r["message"] and chain.sent == []


def test_endpoint_on_the_wrong_chain_is_refused(client, auth, monkeypatch):
    chain = FakeChain(chain_id=1)                                       # configured Sepolia, endpoint is mainnet
    _setup(monkeypatch, chain)
    r = client.post("/api/anchors/run", headers=auth).json()
    assert r["status"] == "error" and "expected 11155111" in r["message"] and chain.sent == []


def test_an_empty_wallet_sends_nothing(client, auth, monkeypatch):
    chain = FakeChain(balance=0)
    wallet = _setup(monkeypatch, chain)
    r = client.post("/api/anchors/run", headers=auth).json()
    assert r["status"] == "unfunded" and r["address"] == wallet and chain.sent == []


def test_blockchain_down_never_breaks_payments(client, auth, monkeypatch, phone):
    chain = FakeChain()
    _setup(monkeypatch, chain)
    _run_and_mine(client, auth, chain)
    chain.fail = True
    monkeypatch.setattr(anchor, "_onchain", {})
    assert client.post("/api/anchors/run", headers=auth).json()["status"] == "error"
    act = money_action(chat(client, auth, "send 300 CNY to mother"))
    assert phone.verify(act["action_id"]).status_code == 200            # payments don't touch the blockchain
    check = client.get("/api/audit/verify", headers=auth).json()
    assert check["valid"] is True and check["anchoring"]["on_chain"] == "unavailable"


def test_receipt_shows_when_its_payment_is_anchored(client, auth, monkeypatch, phone):
    chain = FakeChain()
    _setup(monkeypatch, chain)
    act = money_action(chat(client, auth, "send 300 CNY to mother"))
    tx_id = phone.verify(act["action_id"]).json()["transaction_id"]
    assert client.get(f"/api/transactions/{tx_id}/receipt", headers=auth).json()["anchor"]["state"] == "pending"
    _run_and_mine(client, auth, chain)
    receipt = client.get(f"/api/transactions/{tx_id}/receipt", headers=auth).json()
    assert receipt["anchor"]["state"] == "anchored" and receipt["anchor"]["tx_hash"] == chain.sent[0]
    public = client.get(f"/api/receipts/verify?reference={receipt['reference']}"
                        f"&code={receipt['verification_code'].replace('-', '')}").json()
    assert public["valid"] is True and public["anchor"]["state"] == "anchored"


def test_anchoring_is_off_by_default(client, auth):
    assert client.post("/api/anchors/run", headers=auth).json()["status"] == "disabled"
    assert client.get("/api/anchors").json()["enabled"] is False
