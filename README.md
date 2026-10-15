# MoneyMate Agent

**An AI agent that pays tuition and moves money across borders for international students, with a
hybrid ML fraud guard and permission tiers. The agent plans and prepares every payment, but it never moves
money on its own: each one is completed only after the student verifies it on their Android phone.**

Built for the 2026 Shenzhen International FinTech Competition (FinTechathon), International Track,
**Topic C: Cross-border & Student Finance Assistant**. Theme: *AI as a Financial Participant*.

> Sandbox: accounts, balances and remittance providers are simulated; exchange rates are live mid-market
> rates. No real money moves. Full feature list with the real-world problem behind each: [docs/FEATURES.md](docs/FEATURES.md).

## What the agent does

| Task (Topic C) | What happens |
|---|---|
| **Tuition payments** | "Pay my tuition" → finds the open invoice, verifies the payee against the official university registry, scores risk. If the wallet is short, it plans the conversion from the home currency too: one plan (convert, then pay), one verification. Fake agents, "discounts" and look-alike accounts are blocked. |
| **Remittances** | "Send 2000 CNY to mother" → compares providers (fee + FX margin), picks the cheapest, scores risk and prepares the transfer. Even a small transfer to family waits for the student's verification. |
| **Standing instructions** | "Every month send 1000 CNY to father on 3rd" → on the due day the agent prepares the payment and asks the student to verify it (24 h window). Never prepared twice in a month. |
| **Daily monitor + notifications** | Every morning the agent checks tuition deadlines, standing instructions due, large money from first-time senders and low balance, and notifies the student. Every prepared payment sends "Verify to complete your payment". |
| **Money-mule shield** | Money received from a first-time sender and quickly forwarded to a new payee is blocked before the student becomes a mule; a warning is sent the moment large money arrives from someone new. |
| **Tuition deadline reminders** | Warns 14, 7 and 3 days before the due date (and when overdue), shows whether the wallet covers the invoice and what converting from the home currency costs today. |
| **Multi-currency management** | BDT / CNY / USD wallets and conversion at live mid-market rates (ExchangeRate-API, hourly; snapshot fallback). Conversions are verified like payments. |
| **Scam check** | Paste any invoice, email or message: rule-based red flags (urgency, discounts, threats, crypto / gift cards, secrecy, impersonated accounts) plus a Gemini second opinion that can raise, never lower, the warning. |
| **Payment proof** | Every completed payment gets a receipt (reference, details, PDF) with an HMAC verification code that anyone can check at a public link; any change to the payment invalidates it. |

## How a request is handled

```
Client (app / API)     Daily monitor (every morning: deadlines, standing instructions,
        │              new-sender money, low balance)
        ▼                       │ prepares scheduled payments
AI agent (Gemini function calling, or offline intent parser)
        │ proposes a tool call  │
        ▼                       ▼
   Tool layer ──► read tools (T0): balances, quotes, payee check, scam check, reminders, receipts
        │
        ▼ money tools (pay tuition, send money, convert, scheduled payment)
Behavioural features (20) ──► Hybrid risk model ──► Policy engine
                               6 base models          T2 VERIFY: prepared, waits for the student
                               + LR meta-learner      T3 BLOCK: refused with reasons
        ▼
Prepared payment + "Verify to complete your payment" notification + audit entry
        ▼
Student verifies on their Android phone (fingerprint / face unlock signs a one-time challenge)
        ▼
Money moves in the sandbox ledger ──► receipt + "Payment complete" notification
```

The LLM never decides whether money moves, and the agent cannot move money at all. The policy engine
decides whether a payment may be prepared or must be blocked; only a signature from the student's
registered phone completes it. Verification never comes from chat text, so instructions hidden inside a
pasted invoice cannot approve a payment.

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
| T0 Read | balances, quotes, checks, reminders, receipts, setting up a standing instruction | runs immediately; no money moves |
| T2 Verify | **every** movement of money that is not blocked: payments, transfers, own-wallet conversions, scheduled payments | prepared, then waits for the student to verify on their phone (15 min; 24 h for scheduled payments) |
| T3 Block | HIGH risk, impersonated institution account, mule pattern, crypto / gift card to a person, tuition to an unverified account | refused with reasons |

There is deliberately **no auto-execute tier** (the earlier T1 tier was removed): the agent never moves
money without the student's verification, however small the amount or familiar the payee.

### Device verification

The Android app creates a P-256 (ECDSA) key pair in the Android Keystore (StrongBox when the phone has it,
otherwise the TEE). The key requires user authentication, is unlocked for each use by BiometricPrompt
(fingerprint / face unlock, `BIOMETRIC_STRONG`) and is invalidated when a new biometric is enrolled. Only the
public key is registered: `POST /api/devices` with `key_type: "p256"` and the base64 X.509
SubjectPublicKeyInfo from `getPublicKey().getEncoded()`. Registering a phone sends a "New phone added"
notification. Each prepared payment gets a one-time nonce; the phone fetches
`GET /api/agent/actions/{id}/challenge`, signs `moneymate-verify:{action_id}:{nonce}` with
`SHA256withECDSA` and sends `POST /api/agent/actions/{id}/verify` with `device_id` and the DER `signature`.
The server checks the signature with the stored key, that the phone belongs to the same student and that the
request has not expired, then clears the nonce so the signature cannot be replayed. A stolen password or a
message to the agent cannot produce this signature. Ed25519 keys (`key_type: "ed25519"`, 32 raw bytes) are
also accepted, for test clients; EC keys on any curve other than P-256 are refused.

Push notifications go to the app through Firebase Cloud Messaging (FCM HTTP v1), off by default
(`PUSH_ENABLED`, `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_FILE`). The app updates its FCM token with
`POST /api/devices/{id}/push-token`.

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

The Android app is maintained separately and is not part of this repository (see
[Android app](#android-app) below). Everything can be exercised through the interactive API docs at <http://localhost:8000/docs>: call `POST /api/auth/login`
with the demo student `ayesha` (password = `DEMO_USER_PASSWORD` in `backend/.env`, default `Demo@2026`,
sandbox only), click **Authorize** with the returned token, then try `POST /api/agent/chat` with
`{"message": "Pay my tuition"}`. The answer is `AWAITING_VERIFICATION` with a two-step `plan` (convert BDT,
then pay) and a `VERIFY_PAYMENT` notification (`GET /api/notifications`).

**Completing a payment in a demo.** Two options:

1. **Real device flow** (default, `VERIFICATION_MODE=device`): register a public key and sign the challenge.
   This short script plays the phone (the `cryptography` package is installed with the backend):

   ```python
   import base64
   from cryptography.hazmat.primitives import hashes
   from cryptography.hazmat.primitives.asymmetric import ec
   from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
   key = ec.generate_private_key(ec.SECP256R1())          # same key type as the Android Keystore key
   pub = key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
   print(base64.b64encode(pub).decode())
   # POST /api/devices {"name": "My phone", "key_type": "p256", "public_key": "<printed value>"}  -> {"id": ...}
   # GET  /api/agent/actions/{id}/challenge                                    -> {"challenge": "..."}
   challenge = "moneymate-verify:..."   # paste the challenge text
   print(base64.b64encode(key.sign(challenge.encode(), ec.ECDSA(hashes.SHA256()))).decode())
   # POST /api/agent/actions/{id}/verify {"device_id": ..., "signature": "<printed value>"}
   ```

2. **API-docs shortcut:** set `VERIFICATION_MODE=sandbox` in `backend/.env` and restart; then
   `POST /api/agent/actions/{id}/verify` with `{"sandbox": true}` completes the payment. This skips the
   phone entirely, so it is for demos only and must never be enabled in production.

To show the daily monitor without waiting for the morning, call `POST /api/monitor/run` (optionally with
`?day=YYYY-MM-DD` to simulate a date, e.g. the 1st of next month to see the monthly payment to mother
prepared; simulated dates are refused when `ENVIRONMENT=production`).

**Gemini:** get a free key at <https://aistudio.google.com/apikey> and set `GEMINI_API_KEY`.
Without a key (or when the free quota runs out) the agent uses a deterministic intent parser that calls
the same tools, so the demo always works.

### Android app

The client is an Android app (Flutter UI, with a small Kotlin platform channel for the Keystore key and
BiometricPrompt). [docs/ANDROID_INTEGRATION.md](docs/ANDROID_INTEGRATION.md) covers the key, FCM push and
every API call it makes. To run the backend for the phone, listen on all interfaces:

```bash
cd backend && uvicorn app.main:app --host 0.0.0.0 --port 8000
```

The Android emulator reaches it at `http://10.0.2.2:8000/api`; a phone on the same Wi-Fi uses
`http://<laptop-LAN-IP>:8000/api`. Plain `http` is for debug builds only.

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

51 tests, all passing. The tests play the phone with real key pairs: an Android-Keystore-style P-256 key
(`AndroidPhone` in `tests/conftest.py`) and an Ed25519 test-client key (`Phone`, used by the older tests).

- **End-to-end scenarios** (`test_scenarios.py`, 12): tuition with a planned conversion and one
  verification, fake-invoice impersonation block, even a small family transfer waits for verification
  (and sends the notification), crypto-to-stranger block, money-mule block, prompt injection in a pasted
  invoice, another user cannot verify, a blocked payment cannot be verified, provider ranking, audit-chain
  tamper detection, authentication.
- **Verification, scheduling and monitor** (`test_verification.py`, 13): no signature → 403, wrong
  signature, another student's phone, replayed signature, expired request, reject, conversion needs
  verification, sandbox mode works only when enabled, a standing instruction is prepared on its due day
  and waits (and is not prepared twice), standing instruction set up by chat, mule alert on money from a
  stranger, tuition reminder notified once, notifications marked read.
- **Features** (`test_features.py`, 19): reminder stages and shortfall, reminder logged once, receipt
  verification and tamper detection, receipt PDF, no receipt before verification, receipt access control,
  live FX with offline fallback, and the Gemini second opinion (escalates, never downgrades, falls back on
  errors) with a mocked model.
- **Android** (`test_android.py`, 7): a P-256 Keystore key verifies a payment, a P-256 signature for another
  payment fails, a key on the wrong curve is refused, a new phone triggers an alert, the push token can be
  rotated, the FCM message format (mocked token and HTTP), and a push failure does not break the payment.

## Project layout

```
backend/
  app/
    core/            config, database, auth (JWT + bcrypt)
    models/          users, wallets, payees, invoices, transactions, standing instructions,
                     agent actions, devices, notifications, audit log
    routes/          REST API (auth, finance, agent, mobile: devices / notifications /
                     standing instructions / monitor, audit / model card / sandbox)
    services/
      agent/         Gemini orchestrator, tools, offline intent parser, scam second opinion
      risk/          feature builder, hybrid scorer, live engine with explanations
      policy.py      permission tiers (T0 read, T2 verify, T3 block)
      payments.py    tuition / remittance / FX pipeline, verify and reject
      devices.py     Android phone key registration (P-256; Ed25519 for test clients), signature check
      notify.py      in-app notifications, optional Firebase Cloud Messaging push
      standing.py    standing instructions (recurring payments)
      monitor.py     daily monitor and its background scheduler
      verification.py payee registry check + scam red flags
      reminders.py   tuition deadline reminders
      receipts.py    payment receipts, HMAC verification codes, PDF
      audit.py       hash-chained audit log
      sandbox.py     simulated wallets and providers, live FX rates with fallback
  ml/                synthetic data generator, training pipeline, model artifact
  tests/             scenarios, verification / monitor tests, feature tests, Android key and push tests
docs/                features, technical documentation, security self-assessment, Android integration guide
```

## Scope and honesty notes

- Payments are simulated. Production would call licensed partners (banks, payment institutions);
  MoneyMate never holds funds.
- Exchange rates are live mid-market rates (ExchangeRate-API open access, attribution required); provider
  fees and margins are fictional.
- The deployed model is trained on synthetic data (see above).
- The Gemini second opinion sends the pasted message text to Google's Gemini API; leave `GEMINI_API_KEY`
  empty to keep everything local.
- Device verification is implemented on the server; the Android app that holds the key is a separate
  client. The server cannot yet prove the key really sits in the Keystore behind a biometric (no key
  attestation check), adding a phone needs only the login token (the student is notified, but there is no
  step-up), and there is no way to remove a phone or recover from a lost one. `VERIFICATION_MODE=sandbox`
  turns verification into a single API call; the server refuses to start with it when
  `ENVIRONMENT=production`.
- Push notifications (off by default) send each notification's title and body through Google's Firebase
  Cloud Messaging.
- A scheduled payment the wallet cannot cover is not prepared; the student gets a notification instead
  (no automatic conversion for scheduled payments yet).
