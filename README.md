# MoneyMate Agent

## Summary

MoneyMate is an AI agent that helps international students pay tuition, send money home and manage money in more
than one currency. It was built for the 2026 Shenzhen FinTechathon, International Track, **Topic C: Cross-border &
Student Finance Assistant**.

The agent plans and prepares every payment: it finds the tuition invoice, checks the payee against the official
university registry, converts currency when the wallet is short, compares providers for the cheapest transfer and
scores fraud risk with a hybrid machine-learning model. **It never moves money on its own.** Every payment waits for
the student to verify it on their Android phone with a fingerprint, which signs a one-time challenge with a key in
the phone's secure hardware.

Scam requests (fake tuition accounts, money-mule transfers, prompt injection in pasted messages) are blocked before
money moves. Every action is written to a hash-chained audit log that is anchored on the Ethereum Sepolia test
network, so it can't be rewritten unnoticed.

The project has two parts: a **FastAPI backend** (`backend/`) and a **Flutter Android app** (`app/`).

> Sandbox: accounts, balances and providers are simulated; exchange rates are live. No real money moves.

## Deployment instructions

### Run locally

Requirements: Python 3.11+ (or Docker) for the backend; Flutter (Dart 3.13+) and the Android SDK for the app.

**1. Backend** on <http://localhost:8000> (API docs at <http://localhost:8000/docs>)

```bash
cd backend
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env        # set JWT_SECRET_KEY; GEMINI_API_KEY is optional
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

The database is created and seeded with a demo student on first start.

**2. Android app** (emulator or phone, Android 6.0 / API 23+)

```bash
cd app
flutter pub get
flutter run
```

The emulator reaches the backend at `10.0.2.2:8000`. For a phone on the same Wi-Fi:

```bash
flutter run --dart-define=API_BASE=http://<laptop-ip>:8000/api --dart-define=PUBLIC_BASE=http://<laptop-ip>:8000
```

Sign in as the demo student **`ayesha`** (password: `DEMO_USER_PASSWORD` in `backend/.env`, default `Demo@2026`).
To verify payments, the phone needs a screen lock and an enrolled fingerprint.

### Deploy to a server

A server with 1–2 vCPU and 2 GB RAM is enough. The backend runs as a Docker image
([backend/Dockerfile](backend/Dockerfile)).

**1. Build and run**

```bash
git clone https://github.com/Kiyas-Mahmud/MoneyMate-Agent.git
cd MoneyMate-Agent/backend
cp .env.example .env        # fill in the settings below
docker build -t moneymate-backend .
docker run -d --name moneymate --restart unless-stopped \
  -p 127.0.0.1:8000:8000 --env-file .env -v moneymate-data:/data moneymate-backend
curl http://127.0.0.1:8000/api/anchors     # health check
```

The database is stored in the `moneymate-data` volume, so data survives restarts and upgrades.

**2. Settings** in `backend/.env` (template: [backend/.env.example](backend/.env.example)):

```
JWT_SECRET_KEY=<python -c "import secrets; print(secrets.token_urlsafe(48))">
RECEIPT_SIGNING_KEY=<another long random value; keep it stable>
PUBLIC_BASE_URL=https://api.your-domain.com
CORS_ORIGINS=https://api.your-domain.com
VERIFICATION_MODE=device
ENVIRONMENT=production       # keep "development" for a demo server with the sandbox tools
GEMINI_API_KEY=              # optional: free key at https://aistudio.google.com/apikey
```

Optional: `ANCHOR_ENABLED=true` and `ANCHOR_PRIVATE_KEY` (a fresh wallet funded from a Sepolia faucet) for
blockchain anchoring; `PUSH_ENABLED=true` with Firebase settings for push notifications. Never commit `.env`.

**3. HTTPS.** Release builds of the app only connect over `https://`. Put a reverse proxy with automatic TLS in
front, for example [Caddy](https://caddyserver.com) with this `Caddyfile`, after pointing the domain's DNS at the
server:

```
api.your-domain.com {
    reverse_proxy 127.0.0.1:8000
}
```

**4. Build the release APK for the server**

```bash
cd app
flutter build apk --release \
  --dart-define=API_BASE=https://api.your-domain.com/api \
  --dart-define=PUBLIC_BASE=https://api.your-domain.com
# output: app/build/app/outputs/flutter-apk/app-release.apk
```

**Upgrade:** `git pull`, rebuild the image, then `docker rm -f moneymate` and run it again with the same volume.

## Test cases

```bash
cd backend && python -m pytest -q        # 86 backend tests
cd app && flutter test                   # 15 app tests
```

All tests pass. The backend tests use a fresh database and no network; they play the phone with real key pairs
(an Android-Keystore-style P-256 key).

| File | Tests | What is tested |
|---|---|---|
| `backend/tests/test_scenarios.py` | 26 | Tuition payment with a planned currency conversion and one verification; fake tuition invoice blocked; even a small family transfer waits for verification; crypto transfer to a stranger blocked; money-mule transfer blocked; prompt injection in a pasted invoice can't approve a payment; another user can't verify a payment; audit log tampering is detected; amounts and account numbers parsed correctly |
| `backend/tests/test_verification.py` | 13 | No signature, wrong signature, another student's phone, replayed signature and expired request are all refused; the student can reject; standing instructions are prepared on the due day and wait; money-mule alerts; notifications |
| `backend/tests/test_features.py` | 23 | Tuition reminders; receipts verify and fail after any change; live exchange rates with offline fallback; the AI second opinion can raise a scam warning but never lower it; Gemini model fallback and timeout |
| `backend/tests/test_anchor.py` | 9 | The blockchain anchor holds the audit log's hash; a rewritten log is caught; mainnet and wrong networks are refused; an empty wallet sends nothing; a blockchain outage never blocks payments |
| `backend/tests/test_history.py` | 8 | Payments counted on time, late or missed; a report verifies publicly without showing payees; report PDFs are private |
| `backend/tests/test_android.py` | 7 | A P-256 phone key verifies a payment; wrong key curve refused; new-phone alert; push token rotation; push failure doesn't break a payment |
| `app/test/` | 15 | Payment action cards, number and date formatting, and the blockchain anchor line on receipts |
