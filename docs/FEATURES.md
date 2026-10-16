# MoneyMate Agent: features

MoneyMate is an AI agent for international students. The student asks in plain words; the agent plans and
prepares the task. Every feature below solves a documented, real problem for international and
cross-border students (FinTechathon 2026, Topic C).

> **The verification rule: the agent never moves money on its own.** Every payment, transfer, currency
> conversion and scheduled payment is prepared by the agent and completed only after the student verifies
> it on their registered Android phone (fingerprint / face unlock signs a one-time challenge). There is no
> auto-payment tier, whatever the amount or payee. Risky payments are not even offered for verification:
> they are blocked with reasons. When a payment is prepared, the student gets the notification
> *"Verify to complete your payment … Please complete verification to complete the payment."*

All features are available through the REST API (`/docs` on the backend) and through the agent
(`POST /api/agent/chat`). The client is an Android app; how it holds the payment key, receives push
notifications and calls the API is described in [ANDROID_INTEGRATION.md](ANDROID_INTEGRATION.md).

---

## 1. Safe tuition payment

**What it does.** "Pay my tuition" → the agent finds the open invoice, checks that the bank account is the
university's official one, scores the risk and prepares the payment. If the study-currency wallet is
short, it also plans the conversion from the home currency: **one plan, one verification**. The response
lists both steps (`plan`: convert, then pay); after the student verifies once, the conversion runs and
then the tuition is paid.

**Real problem.** Fake agents and look-alike accounts steal tuition: two men were charged in Canada in 2026
for taking $126,000 from students with fake enrolment documents; a student lost $27,000 paying tuition
through a WeChat "agent".

**Protection.** Accounts that pretend to be the university, "discount" offers and personal accounts are
blocked. Nothing is paid until the student verifies on their phone.

**API.** `POST /api/tuition/pay`, `GET /api/tuition/invoices`, `POST /api/payees/verify` · agent tool `pay_tuition`

## 2. Tuition deadline reminders

**What it does.** Warns 14, 7 and 3 days before the due date and when overdue, and says whether the wallet
covers the invoice. If it does not, it shows what converting from the home currency costs today:
*"Spring 2027 tuition (26,000 CNY) is due in 6 days. Your CNY wallet is short by 8,000 CNY; converting about
149,000 BDT today would cover it."*

**Real problem.** Late tuition means late fees, enrolment holds and, for visa holders, risk to full-time
status. Money from home also takes days to arrive.

**API.** `GET /api/tuition/reminders` · agent tool `get_tuition_reminders` · every chat response carries active
`reminders` · each new stage is written to the audit log once and sent once as a `TUITION_REMINDER`
notification (feature 9).

## 3. Scam message check (rules + Gemini second opinion)

**What it does.** The student pastes any message asking for money (email, SMS, WeChat/WhatsApp, invoice) and
gets an instant verdict with reasons and one safe next step.

- **Rules** (deterministic): urgency, fake discounts, visa/enrolment threats, crypto or gift cards, secrecy
  requests, and payee accounts that impersonate a registered university.
- **Gemini second opinion**: reads the message independently and explains it in plain words, catching new
  wording the rules miss. It can only raise the warning level, never lower it, and it is never used to
  approve payments. Without a Gemini key the rules work alone.

**Real problem.** An IEEE S&P 2026 study of international students found 41.7% faced finance-related scams
and recommends verification *while* the scam is happening.

**API.** `POST /api/scam-check` · agent tool `analyze_payment_request`

## 4. Smart money transfer

**What it does.** "Send 2000 CNY to mother" → compares providers (fee + exchange-rate margin over the live
mid-market rate), picks the cheapest and prepares the transfer. It is sent after the student verifies it.

**Real problem.** Sending $200 costs 6.36% on average worldwide (World Bank, Q3 2025), every month.

**Protection.** No transfer is sent automatically, not even a small one to known family: every transfer
waits for the student's verification. A first payment to a new recipient or a MEDIUM risk score is pointed
out on the verification request; hard-to-reverse channels (crypto, gift cards) to private people, money-mule
patterns and HIGH risk are blocked.

**API.** `POST /api/remittance/compare`, `POST /api/remittance/send` · agent tools `compare_remittance_providers`, `send_remittance`

## 5. Money-mule shield

**What it does.** Blocks forwarding money that just arrived from a first-time sender (e.g. a "part-time
job payment") to a new recipient, and explains why. It also warns earlier: the moment the equivalent of
$300 or more arrives from someone the student has never received money from, a `MULE_ALERT` notification
says not to forward it.

**Real problem.** Europol names students and newcomers as main recruitment targets for money mules; a
student caught as a mule can lose their bank account and visa.

**API.** Part of every outgoing payment check; `POST /api/sandbox/incoming` simulates the incoming money for demos.
The daily monitor (feature 9) re-checks the last 72 hours without sending duplicate warnings.

## 6. Multi-currency wallet with live rates

**What it does.** Balances in home and study currencies (e.g. BDT, CNY, USD) and conversion between them, at
live mid-market rates (ExchangeRate-API, refreshed hourly; dated snapshot if the API is unreachable).
A conversion stays between the student's own wallets, but it still waits for verification like a payment.

**Real problem.** Students live in two currencies; every conversion costs money and timing matters.

**API.** `GET /api/wallet`, `POST /api/wallet/convert` · agent tools `get_wallet_balances`, `get_fx_quote`, `convert_currency`

## 7. Payment proof for every transaction

**What it does.** Every completed payment gets a receipt: reference number, amount, payee, date, whether the
payee is a verified institution, how it was approved, and a verification code. Downloadable as PDF.
Anyone (landlord, university, visa office) can check a receipt at a public link without an account;
changing any detail makes the code invalid. Payments show the approval line "Verified by the student on
their phone".

**Real problem.** Universities, visa offices, landlords and banks ask students for proof of payment, and a
student's payment history at home does not follow them abroad.

**API.** `GET /api/transactions/{id}/receipt`, `GET /api/transactions/{id}/receipt.pdf`,
public `GET /api/receipts/verify?reference=&code=` · agent tool `get_payment_receipt`

## 8. Standing instructions (recurring payments)

**What it does.** "Every month send 1000 CNY to father on 3rd" → the agent saves a standing instruction
(day 1 to 28, saved recipients only). On the due day the daily monitor prepares the payment through the
normal pipeline (cheapest provider, risk check, policy) and sends a "Scheduled payment ready … Please
complete verification to complete the payment" notification. The student has 24 hours to verify. Each
instruction is prepared at most once per month, and can be paused or resumed. The demo student starts
with two: 1,500 CNY to her mother on day 1 and 2,800 CNY rent on day 5.

**Real problem.** Students send money home and pay rent every month; forgetting means a late fee or a
family waiting, while fully automatic standing orders would let a mistake or a scam repeat unnoticed.

**Protection.** A scheduled payment is never sent without verification, and a risky one is blocked like
any other payment. If the wallet cannot cover it, it is not prepared and the student is told why.

**API.** `GET /api/standing-instructions`, `POST /api/standing-instructions`,
`POST /api/standing-instructions/{id}/pause`, `POST /api/standing-instructions/{id}/resume` · agent tools
`create_standing_instruction`, `list_standing_instructions`

## 9. Daily monitor and notifications

**What it does.** Every morning (at `MONITOR_HOUR`, default 08:00 server time) the agent runs its own
routine for each student, without being asked:

1. tuition deadlines (14 / 7 / 3 days, overdue), with the shortfall and conversion cost;
2. standing instructions due → prepared and sent for verification (feature 8);
3. large money from first-time senders in the last 72 hours → money-mule warning;
4. low study-currency balance for standing instructions due in the next 7 days.

Every finding becomes a notification. Notification types: `VERIFY_PAYMENT` (a prepared payment waits for
verification), `PAYMENT_DONE` (with the receipt reference), `PAYMENT_BLOCKED`, `TUITION_REMINDER`,
`MULE_ALERT`, `LOW_BALANCE` and `DEVICE_ADDED` ("New phone added … If this wasn't you, contact support right
away", sent whenever a phone is registered). Optional push to every registered Android phone through
Firebase Cloud Messaging (off by default, best effort; the in-app list is always the source of truth).
Payment requests, blocked payments and mule alerts use the high-priority `payments` channel so the
"verify" prompt shows as a heads-up notification; everything else uses `updates`. Each monitor run is
written to the audit log.

**Real problem.** The moments that matter (a deadline, a payment due, a stranger's transfer) happen when
the student is not looking at a finance app.

**API.** `GET /api/notifications` (`?unread=true`), `POST /api/notifications/{id}/read`,
`POST /api/notifications/read-all`, `POST /api/monitor/run` (runs it now; `?day=YYYY-MM-DD` simulates a date
in the sandbox) · phone registration `POST /api/devices`, `GET /api/devices`, FCM token update
`POST /api/devices/{id}/push-token`

## 10. Payment history report (credit building)

**What it does.** A record of the student's regular payments made through MoneyMate: rent and family support
(from standing instructions) and tuition, for the last 3, 6 or 12 months. Each payment that was due is
marked **on time**, **late** or **missed**: monthly payments are on time if paid by the due day plus 3 days,
tuition by its due date. The app shows the on-time rate, a month-by-month timeline and a breakdown by type
(Profile → Payment history). The student can issue a **verifiable report**: a PDF with a reference, a QR code
and an HMAC verification code. A landlord, bank or university checks it at a public link without an account
and sees the summary (on-time counts by type, the period, who it was issued to), but not the payees or
amounts. An issued report is a snapshot: later payments don't change it, and any edit makes the code fail.
The agent explains the record when asked ("my landlord wants proof I pay rent on time").

**Real problem.** International students arrive with no local credit history, so landlords ask for large
deposits or guarantors and banks hesitate to offer accounts or cards. Their reliable payment record at home
doesn't follow them.

**What it is not.** It is not a credit score: there is no made-up number, only payments that really
happened, with the rules shown on the report. Card spending and conversions between the student's own
wallets are left out. Reporting to credit bureaus would need licensed partners and is on the roadmap.

**API.** `GET /api/history?months=6` (the student's own record), `POST /api/history/reports` (issue),
`GET /api/history/reports`, `GET /api/history/reports/{reference}/pdf`, public
`GET /api/history/verify?reference=&code=` · agent tool `get_payment_history`

---

## Safety layer behind every feature

| Part | What it does |
|---|---|
| **Hybrid ML risk check** | Each payment is scored by 6 models (Logistic Regression, Random Forest, XGBoost, Gradient Boosting, neural network, autoencoder) combined by a meta-learner, with plain-language reasons |
| **Permission tiers** | T0 read · T2 verify (every movement of money: payments, transfers, conversions, scheduled payments) · T3 blocked. There is no auto-execute tier |
| **Device verification** | A P-256 key in the phone's Android Keystore (StrongBox when available, otherwise the TEE), unlocked for each use by fingerprint / face unlock (Android BiometricPrompt), signs a one-time challenge for each payment. The server checks the signature, the owner and the expiry (15 min; 24 h for scheduled payments), and a signature cannot be reused. Adding a phone notifies the student. Only the student can approve; the AI cannot |
| **Tamper-evident audit log** | Every agent action, decision, verification, reminder, monitor run and payment is recorded in a hash chain; any edit is detectable |
| **Blockchain anchoring** | Every day the chain's latest hash is written to the Ethereum Sepolia test network (`POST /api/anchors/run` to do it now). Verification compares the log with the on-chain copy, so even a consistent rewrite of the whole log is caught. Receipts and payment history reports show "Secured on blockchain" with an explorer link. Only hashes go on-chain; test networks only; `GET /api/anchors` lists every anchor |

## Not included (removed on purpose)

- **Credit-style "reliability score"**: it looked like a fake credit score. Feature 10 covers the real need
  instead: a verifiable record of on-time payments, with no invented number.
- **FX planner screen**: its useful part is now in feature 2 (shortfall and conversion cost before the deadline).

## Honest scope

- Payments run in a sandbox: simulated accounts, no real money. Production would use licensed bank and payment partners.
- Exchange rates are live mid-market rates; provider fees and margins are fictional.
- The risk model is trained on synthetic data built from documented fraud patterns (no public dataset covers student tuition and remittance fraud).
- The server side of device verification is complete; the Android app that holds the key is a separate client. The server does not check key attestation yet, adding a phone needs only the login token (the student is notified), and there is no way to remove a phone or recover from a lost one. For demos through the API docs, `VERIFICATION_MODE=sandbox` accepts `{"sandbox": true}` instead of a signature; the server refuses to start with it when `ENVIRONMENT=production`.
- A scheduled payment that the wallet cannot cover is not prepared; the student gets a notification instead. There is no automatic conversion for scheduled payments yet (tuition has one).
- The daily monitor runs inside the API process at server local time; push notifications use Firebase Cloud Messaging (Google), are off by default and are not retried.
