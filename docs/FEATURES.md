# MoneyMate Agent: features

MoneyMate is an AI agent for international students. The student asks in plain words; the agent does the
task. A safety layer decides what the agent may do on its own. Every feature below solves a documented,
real problem for international and cross-border students (FinTechathon 2026, Topic C).

All features are available through the REST API (`/docs` on the backend) and through the agent
(`POST /api/agent/chat`).

---

## 1. Safe tuition payment

**What it does.** "Pay my tuition" → the agent finds the open invoice, checks that the bank account is the
university's official one, scores the risk and asks the student to confirm before paying.

**Real problem.** Fake agents and look-alike accounts steal tuition: two men were charged in Canada in 2026
for taking $126,000 from students with fake enrolment documents; a student lost $27,000 paying tuition
through a WeChat "agent".

**Protection.** Accounts that pretend to be the university, "discount" offers and personal accounts are
blocked. Tuition always needs the student's confirmation.

**API.** `POST /api/tuition/pay`, `GET /api/tuition/invoices`, `POST /api/payees/verify` · agent tool `pay_tuition`

## 2. Tuition deadline reminders

**What it does.** Warns 14, 7 and 3 days before the due date and when overdue, and says whether the wallet
covers the invoice. If it does not, it shows what converting from the home currency costs today:
*"Spring 2027 tuition (26,000 CNY) is due in 6 days. Your CNY wallet is short by 8,000 CNY; converting about
149,000 BDT today would cover it."*

**Real problem.** Late tuition means late fees, enrolment holds and, for visa holders, risk to full-time
status. Money from home also takes days to arrive.

**API.** `GET /api/tuition/reminders` · agent tool `get_tuition_reminders` · every chat response carries active
`reminders` · each new stage is written to the audit log once.

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
mid-market rate), picks the cheapest and sends.

**Real problem.** Sending $200 costs 6.36% on average worldwide (World Bank, Q3 2025), every month.

**Protection.** Small transfers to known family run automatically; new recipients, large or unusual amounts
need confirmation; hard-to-reverse channels (crypto, gift cards) to private people are blocked.

**API.** `POST /api/remittance/compare`, `POST /api/remittance/send` · agent tools `compare_remittance_providers`, `send_remittance`

## 5. Money-mule shield

**What it does.** Blocks forwarding money that just arrived from a first-time sender (e.g. a "part-time
job payment") to a new recipient, and explains why.

**Real problem.** Europol names students and newcomers as main recruitment targets for money mules; a
student caught as a mule can lose their bank account and visa.

**API.** Part of every outgoing payment check; `POST /api/sandbox/incoming` simulates the incoming money for demos.

## 6. Multi-currency wallet with live rates

**What it does.** Balances in home and study currencies (e.g. BDT, CNY, USD) and conversion between them, at
live mid-market rates (ExchangeRate-API, refreshed hourly; dated snapshot if the API is unreachable).

**Real problem.** Students live in two currencies; every conversion costs money and timing matters.

**API.** `GET /api/wallet`, `POST /api/wallet/convert` · agent tools `get_wallet_balances`, `get_fx_quote`, `convert_currency`

## 7. Payment proof for every transaction

**What it does.** Every completed payment gets a receipt: reference number, amount, payee, date, whether the
payee is a verified institution, how it was approved, and a verification code. Downloadable as PDF.
Anyone (landlord, university, visa office) can check a receipt at a public link without an account;
changing any detail makes the code invalid.

**Real problem.** Universities, visa offices, landlords and banks ask students for proof of payment, and a
student's payment history at home does not follow them abroad.

**API.** `GET /api/transactions/{id}/receipt`, `GET /api/transactions/{id}/receipt.pdf`,
public `GET /api/receipts/verify?reference=&code=` · agent tool `get_payment_receipt`

---

## Safety layer behind every feature

| Part | What it does |
|---|---|
| **Hybrid ML risk check** | Each payment is scored by 6 models (Logistic Regression, Random Forest, XGBoost, Gradient Boosting, neural network, autoencoder) combined by a meta-learner, with plain-language reasons |
| **Permission tiers** | T0 read · T1 auto-execute (known payee, low risk, ≤ $200, ≤ $500/day) · T2 student confirms in the app · T3 blocked. Only the student can approve; the AI cannot |
| **Tamper-evident audit log** | Every agent action, decision, reminder and payment is recorded in a hash chain; any edit is detectable |

## Not included (removed on purpose)

- **Credit-style "reliability score"**: it looked like a fake credit score. Feature 7 covers the real need: verifiable proof of payments.
- **FX planner screen**: its useful part is now in feature 2 (shortfall and conversion cost before the deadline).

## Honest scope

- Payments run in a sandbox: simulated accounts, no real money. Production would use licensed bank and payment partners.
- Exchange rates are live mid-market rates; provider fees and margins are fictional.
- The risk model is trained on synthetic data built from documented fraud patterns (no public dataset covers student tuition and remittance fraud).
