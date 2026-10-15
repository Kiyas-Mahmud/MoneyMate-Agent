# MoneyMate Agent

**An AI agent that pays tuition and moves money across borders for international students, with a
hybrid ML fraud guard and permission tiers that decide what the agent may do on its own.**

Built for the 2026 Shenzhen International FinTech Competition (FinTechathon), International Track,
**Topic C: Cross-border & Student Finance Assistant**. Theme: *AI as a Financial Participant*.

> Sandbox: accounts, balances, FX rates and remittance providers are simulated. No real money moves.

## What the agent does

| Task (Topic C) | What happens |
|---|---|
| **Tuition payments** | "Pay my tuition" → finds the open invoice, verifies the payee against the official university registry, scores risk, asks the student to confirm. Fake agents, "discounts" and look-alike accounts are blocked. |
| **Remittances** | "Send 2000 CNY to mother" → compares providers (fee + FX margin), picks the cheapest, scores risk. Small payments to known family run automatically; new or risky recipients need confirmation. |
| **Money-mule shield** | Money received from a first-time sender and quickly forwarded to a new payee is blocked before the student becomes a mule. |
| **Multi-currency management** | BDT / CNY / USD wallets, conversion, tuition FX planner (preview). |
| **Scam check** | Paste any invoice, email or message: red flags (urgency, discounts, threats, crypto / gift cards, secrecy, impersonated accounts) are explained. |
| **Credit building** | Financial Passport: a verified payment-history report for landlords and banks (preview). |

## How a request is handled

```
Client (app / API) ──► AI agent (Gemini function calling, or offline intent parser)
              │ proposes a tool call
              ▼
         Tool layer ──► read tools (T0): balances, quotes, verification, scam check
              │
              ▼ money tools
     Behavioural features (20) ──► Hybrid risk model ──► Policy engine (tiers)
                                    6 base models          T1 auto-execute
                                    + LR meta-learner      T2 student confirms in app
                                                           T3 blocked
              ▼
     Sandbox ledger + agent action + hash-chained audit log
```

The LLM never decides whether money moves. The policy engine does, using the risk score and hard
rules, and confirmations can only come from the authenticated app, never from chat text, so
instructions hidden inside a pasted invoice cannot approve a payment.

### Hybrid risk model

- Base learners: Logistic Regression, Random Forest, XGBoost, HistGradientBoosting, a feed-forward
  neural network, and an autoencoder trained on legitimate payments (anomaly score).
- Out-of-fold predictions train a logistic-regression meta-learner (stacking).
- Explanations: TreeSHAP contributions from the XGBoost learner, turned into plain-language reasons.
- Held-out test (synthetic data): ROC-AUC 0.937, PR-AUC 0.879; at the block threshold precision 98.0%,
  recall 79.8%. See `backend/ml/artifacts/metrics.json`.
- **Data:** no public dataset covers student tuition / remittance fraud, so the deployed model is
  trained on synthetic data generated from documented fraud typologies (`backend/ml/generate_data.py`).
  Our earlier hybrid ensemble (5 ML + 8 DL models) on the real IEEE-CIS benchmark reached ROC-AUC 0.87.
  Partner data (banks, universities) would replace the synthetic set.

### Permission tiers

| Tier | When | Agent behaviour |
|---|---|---|
| T0 Read | balances, quotes, checks | runs immediately |
| T1 Auto | known payee, LOW risk, ≤ $200 per payment and ≤ $500 per day | executes, student notified |
| T2 Confirm | new payee, MEDIUM risk, above limits, any tuition | waits for the student's confirmation (expires in 15 min) |
| T3 Block | HIGH risk, impersonated institution account, mule pattern, crypto / gift card to a person, tuition to an unverified account | refused with reasons |

## Run it locally

Requirements: Python 3.11+.

```bash
# 1. Backend (FastAPI) on http://localhost:8000  (API docs at /docs)
cd backend
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env        # set JWT_SECRET_KEY; GEMINI_API_KEY is optional
uvicorn app.main:app --port 8000
```

The web UI is maintained separately and is not part of this repository. Everything can be exercised
through the interactive API docs at <http://localhost:8000/docs>: call `POST /api/auth/login` with the
demo student `ayesha` (password = `DEMO_USER_PASSWORD` in `backend/.env`, default `Demo@2026`, sandbox
only), click **Authorize** with the returned token, then try `POST /api/agent/chat` with
`{"message": "Pay my tuition"}`.

**Gemini:** get a free key at <https://aistudio.google.com/apikey> and set `GEMINI_API_KEY`.
Without a key (or when the free quota runs out) the agent uses a deterministic intent parser that calls
the same tools, so the demo always works.

### Retrain the model (optional, ~8 min on CPU)

```bash
cd backend
python -m ml.generate_data --rows 80000
python -m ml.train_hybrid
```

### Tests

```bash
cd backend && python -m pytest -q
```

12 end-to-end scenarios: tuition with confirmation, fake-invoice impersonation block, auto-executed
family remittance, crypto-to-stranger block, money-mule block, prompt injection in a pasted invoice,
cross-user confirmation attempt, confirming a blocked action, provider ranking, audit-chain tamper
detection, and authentication.

## Project layout

```
backend/
  app/
    core/            config, database, auth (JWT + bcrypt)
    models/          users, wallets, payees, invoices, transactions, agent actions, audit log
    routes/          REST API (auth, finance, agent, audit / model card / sandbox)
    services/
      agent/         Gemini orchestrator, tool definitions, offline intent parser
      risk/          feature builder, hybrid scorer, live engine with explanations
      policy.py      permission tiers
      payments.py    tuition / remittance / FX pipeline
      verification.py payee registry check + scam red flags
      audit.py       hash-chained audit log
      sandbox.py     simulated wallets, FX rates, providers
  ml/                synthetic data generator, training pipeline, model artifact
  tests/             end-to-end scenarios
docs/                technical documentation, security self-assessment
```

## Scope and honesty notes

- Payments are simulated. Production would call licensed partners (banks, payment institutions);
  MoneyMate never holds funds.
- FX rates and provider prices are a dated sandbox snapshot, not live quotes.
- The deployed model is trained on synthetic data (see above).
- The Financial Passport (`GET /api/credit/passport`) is a preview feature.
