"""Exchange rates and money requests to family at home (sandbox arrival)."""

import pytest

from tests.test_scenarios import balance, chat, money_action


def _family(client, auth, rel="mother"):
    fam = client.get("/api/funds/family", headers=auth).json()
    return next(f for f in fam if f["relationship"] == rel)


def test_rates_cover_every_pair_with_a_best_provider(client, auth):
    r = client.get("/api/fx/rates", headers=auth).json()
    pairs = {(p["from"], p["to"]) for p in r["pairs"]}
    assert {("BDT", "CNY"), ("CNY", "BDT"), ("USD", "CNY"), ("BDT", "USD")} <= pairs
    p = next(p for p in r["pairs"] if p["from"] == "BDT" and p["to"] == "CNY")
    assert p["mid_rate"] > 0 and p["best_rate"] < p["mid_rate"]            # providers price below mid-market
    assert len(r["providers"]) == 4 and r["as_of"]


def test_rates_need_a_login(client):
    assert client.get("/api/fx/rates").status_code == 401


def test_only_family_members_are_offered(client, auth):
    fam = client.get("/api/funds/family", headers=auth).json()
    assert {f["relationship"] for f in fam} == {"mother", "father"}         # the landlord is not family


def test_quote_lists_providers_cheapest_first(client, auth):
    opts = client.get("/api/funds/quote", headers=auth, params={"amount": 8000}).json()["options"]
    sends = [o["send_amount"] for o in opts]
    assert sends == sorted(sends) and len(opts) == 4
    assert all(o["receive_amount"] == 8000 and o["send_currency"] == "BDT" and o["receive_currency"] == "CNY" for o in opts)
    best, bank = opts[0], next(o for o in opts if o["provider_id"] == "bank_wire")
    assert best["send_amount"] < bank["send_amount"]


def test_request_then_family_money_arrives_through_the_chosen_provider(client, auth):
    mother = _family(client, auth)
    before = balance(client, auth, "CNY")
    r = client.post("/api/funds/requests", headers=auth,
                    json={"payee_id": mother["id"], "amount": 8000, "reason": "Spring 2027 tuition"})
    assert r.status_code == 201
    req = r.json()
    assert req["status"] == "REQUESTED" and req["family"]["name"] == mother["name"] and req["options"]
    assert balance(client, auth, "CNY") == before                          # a request moves no money
    cheapest = req["options"][0]
    done = client.post(f"/api/funds/requests/{req['id']}/receive", headers=auth,
                       json={"provider_id": cheapest["provider_id"]}).json()
    assert done["status"] == "RECEIVED" and done["received_via"]["send_amount"] == cheapest["send_amount"]
    assert balance(client, auth, "CNY") == pytest.approx(before + 8000)
    kinds = [n["kind"] for n in client.get("/api/notifications", headers=auth).json()]
    assert "FUNDS_RECEIVED" in kinds and "MULE_ALERT" not in kinds          # family money is not a stranger's
    events = [e["event"] for e in client.get("/api/audit", headers=auth).json()]
    assert "FUNDS_REQUESTED" in events and "FUNDS_RECEIVED" in events


def test_family_money_does_not_block_the_next_payment(client, auth, phone):
    mother = _family(client, auth)
    req = client.post("/api/funds/requests", headers=auth, json={"payee_id": mother["id"], "amount": 8000}).json()
    client.post(f"/api/funds/requests/{req['id']}/receive", headers=auth, json={"provider_id": "remitlite"})
    act = money_action(chat(client, auth, "Please pay my tuition"))        # 18,000 + 8,000 now covers 26,000
    assert act["status"] == "AWAITING_VERIFICATION" and all(s["step"] != "convert" for s in act["plan"])
    assert phone.verify(act["action_id"]).json()["status"] == "VERIFIED"


def test_a_request_cannot_arrive_twice_or_after_cancel(client, auth):
    mother = _family(client, auth)
    a = client.post("/api/funds/requests", headers=auth, json={"payee_id": mother["id"], "amount": 500}).json()
    assert client.post(f"/api/funds/requests/{a['id']}/receive", headers=auth, json={"provider_id": "quicksend"}).status_code == 200
    again = client.post(f"/api/funds/requests/{a['id']}/receive", headers=auth, json={"provider_id": "quicksend"})
    assert again.status_code == 400
    b = client.post("/api/funds/requests", headers=auth, json={"payee_id": mother["id"], "amount": 500}).json()
    assert client.post(f"/api/funds/requests/{b['id']}/cancel", headers=auth).json()["status"] == "CANCELLED"
    assert client.post(f"/api/funds/requests/{b['id']}/receive", headers=auth, json={"provider_id": "quicksend"}).status_code == 400


def test_requests_only_go_to_family_and_stay_private(client, auth):
    landlord = next(p for p in client.get("/api/payees", headers=auth).json()["recipients"] if p.get("relationship") == "landlord")
    r = client.post("/api/funds/requests", headers=auth, json={"payee_id": landlord["id"], "amount": 500})
    assert r.status_code == 400
    mother = _family(client, auth)
    req = client.post("/api/funds/requests", headers=auth, json={"payee_id": mother["id"], "amount": 500}).json()
    other = client.post("/api/auth/register", json={"username": "fundsother1", "password": "Other#2026x",
                                                     "full_name": "Other"}).json()["access_token"]
    h = {"Authorization": f"Bearer {other}"}
    assert client.post(f"/api/funds/requests/{req['id']}/receive", headers=h, json={"provider_id": "remitlite"}).status_code == 400
    assert client.get("/api/funds/requests", headers=h).json() == []
