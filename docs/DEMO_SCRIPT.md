# MoneyMate demo script (5 minutes)

One student, Ayesha (Bangladesh → China), one week before her tuition deadline. Every scene uses the real app
against the real backend in sandbox mode. Times are targets for the video.

## Before recording

- Backend running; in the app: **Profile → Reset demo data** (wallets back to ৳250,000 / ¥18,000 / $300).
- Run today's agent routine so the tuition reminder exists:
  `POST /api/monitor/run` (or wait for the daily 08:00 run).
- **Agent → New chat** (pencil icon) so the conversation starts clean.
- Phone has a screen lock and a fingerprint enrolled (needed for scene 3).

---

## 1. The problem (0:00–0:30)

*Voice-over:* "Every semester, international students move thousands across borders: tuition, rent, money from
home. Scammers know it: fake tuition agents, 'discounts', money-mule jobs. MoneyMate is an AI agent that handles the
money work, but can never move a single yuan without the student's fingerprint."

**Show:** Home. Point at the tuition card: *due in 6 days, short ¥8,000*.

## 2. The agent pays tuition (0:30–1:30)

**Tap** "Pay with agent". The agent:
- sees the wallet is short, plans **convert ৳148,543 → ¥8,000, then pay ¥26,000**;
- checks the payee is the university's **verified account**;
- scores fraud risk with the hybrid model: **Low · 1%**.

*Voice-over:* "One plan, one verification. The agent did the thinking: the rate, the shortfall, the official
account. It did not pay."

**Tap** "Review and verify" → the Verify sheet: plan, account, risk, countdown.

## 3. The student approves (1:30–2:00)

**Tap** "Verify with fingerprint" → system fingerprint prompt → touch → success animation → **Receipt**:
reference, verification code, QR. **Tap** "Share PDF" (show the share sheet, then back out).

*Voice-over:* "The approval is signed by a key inside the phone's secure hardware. The receipt can be checked by a
landlord, a university or a visa office."

## 4. A scam stopped before it starts (2:00–3:00)

**Pay tab → Scam check → Screenshot**, pick the WeChat "Bursary Office" screenshot (Chinese and English). The text
is read **on the phone**. **Tap** "Check message":
- **Likely a scam**, 5 red flags: urgency, a "discount", a WeChat transfer to an agent, "don't contact the
  university", not the official account.

**Tap** "Pay the official way" → Tuition screen.

*Voice-over:* "Scammers copy the university's name. MoneyMate checks the account against the verified registry."

## 5. The money-mule trap (3:00–4:15)

**Profile → Simulate money from a stranger → Simulate.**
→ "Be careful with this money": ¥30,000 from *Global Remote Jobs Ltd*, a first-time sender.

*Voice-over:* "A 'part-time job' pays her ¥30,000 and asks her to forward most of it. This is how students get
recruited as money mules, and lose their bank account or visa."

**Pay → Send money → Add** "Kevin Tan", Malaysia → ¥27,000 → "Review".
→ **We stopped this transfer**: the timeline (received → 1 minute later → blocked), **High · 99%**.

**Tap** "Get help returning the money" → the agent explains the safe way: ask the bank to recall it, never forward
it, report it.

## 6. Proof and control (4:15–4:50)

- **Activity:** every transaction, filters, the blocked transfer with its reason, **Log intact** (hash-chained audit
  log: tap it).
- **Profile → Standing instructions:** rent and money for mother, prepared on the day, **verified every time**.
- **Profile → How MoneyMate protects you.**

## 7. Close (4:50–5:00)

*Voice-over:* "MoneyMate: an AI that participates in your finances, and never acts without you."

---

## If something goes wrong live

| Problem | Fix |
|---|---|
| Signed out mid-demo | Sign-in tokens last 2 hours; sign in again (`ayesha`) |
| Tuition already paid / numbers off | Profile → Reset demo data, then run the monitor again |
| "Can't reach MoneyMate" | Backend not running, or the phone uses the wrong address (`API_BASE`) |
| Verify says "Add a fingerprint" | Enrol one in system settings; the sheet updates when you come back |
| Verify request expired | Requests last 15 minutes; ask the agent again |
