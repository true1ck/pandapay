# PandaPay — Product & Build Plan (India)

*Tells you which of your cards to use for every transaction, at the moment you're about to pay.*

**Revision 5** — reframed from "MVP" to **v1.0 Production Release**. This is not a prototype or a feature demo. It is a real product serving real people's real money, targeting **500+ users from launch**, self-hosted end to end. Everything in Part I must be complete, hardened, and trustworthy — not illustrative.

---

## 1. Positioning

Existing India players solve adjacent problems:
- **Card issuers** (Kiwi, Roarbank, OneCard, Uni, Scapia, Jupiter) — sell you *a* card; don't help you choose *among* your cards.
- **Bill-pay/cashback trackers** (CRED, CheQ, BharatNXT) — reward you for paying bills, not for choosing the right card at point of sale.
- **SaveSage** — closest competitor; spend-pattern recommendation and point tracking, but not payment-moment-aware.

**The moat is two layers, neither of which is a feature list:**
1. **Stateful personalization** — caps, milestones, fee-waiver progress and credit utilization make the right answer different for every user, every week. A static category table cannot produce this.
2. **Our own crowdsourced database** — a payment-verified merchant/category/acceptance map of India built from real transactions. Reward tables can be copied in a weekend; this cannot be copied without an equivalent user base.

---

## 2. What "Production" Means Here — The Standard

This is a **financial application**. Users will make real spending decisions based on its output, and it will hold a detailed record of their financial life. That sets a bar that a demo doesn't have to clear:

1. **No silent failures.** Every error path is handled, logged, and surfaced honestly. A wrong recommendation is worse than no recommendation.
2. **No data loss, ever.** Automated backups, tested restores, versioned schema migrations.
3. **Correct or clearly uncertain.** Every number is labeled estimated or confirmed (§5.11). We never present a guess as fact.
4. **Works offline and degrades gracefully.** Every network dependency has a defined offline behaviour.
5. **Legally compliant from day one.** India's DPDP Act, Play Store data-safety disclosures, and an explicit "not financial advice" position (§8).
6. **Operable by one person.** Monitoring, alerting, and remote kill-switches, because there is no on-call team.
7. **Supportable.** 500 users generate real support load. In-app feedback and a response path are v1.0 scope, not later.

**Explicitly out of scope for v1.0** (both require corporate-scale processes):
- **Account Aggregator** — needs FIU registration.
- **In-app UPI payment** — needs TPAP licensing (company + PSP bank sponsor + NPCI approval + audits).

---

# PART I — v1.0 PRODUCTION RELEASE

## 3. The Core Loop ⭐⭐⭐

The central mechanic. Every scan by one user makes the app *more automatic* for every other user, permanently.

### First user at a location — one scan
1. User opens the scanner, points at the merchant's UPI QR.
2. App decodes: `pa=dmart.powai@hdfcbank`, `pn=DMart`, `mc=5411` (grocery).
3. App captures device coordinates at scan time.
4. **Recommendation appears instantly** — from the MCC, entirely on-device, no network.
5. Tapping the card launches their UPI app with payment details pre-filled.
6. Background contribution stored: `{vpa, name, MCC, grid-snapped coords}` — no user identity.

### Every subsequent user at that location — zero taps
- Geofence fires as they walk in.
- **Notification appears without opening the app or scanning:** *"You're at DMart — use your Axis Ace, 5% back on groceries."*
- If they do scan, it's an instant known-VPA hit that re-confirms the record.

| Situation | User effort |
|---|---|
| Known location (anyone scanned it before) | **Zero — notification appears** |
| Unknown location | One scan — serves them *and* teaches everyone |
| Known merchant, new branch | Instant VPA match; coords added to same record |

### Honest limits on "fully automatic"
- **Scanning needs the camera opened deliberately** — no app can auto-scan. Mitigated by one-tap access from Quick Settings tile, widget, lock screen, app-icon long-press.
- **Payment completes in their UPI app** (TPAP boundary). We pre-fill everything so it's one confirmation, and **the user never scans twice**.
- **Geofence needs location permission.** The app must stay fully useful for users who decline.

---

## 4. Recommendation Core

### 4.1 QR Scan → Recommend → UPI Handoff ⭐ FLAGSHIP
- Decode UPI QR with `mobile_scanner` (free, no license).
- Payload gives `pa` (unique merchant ID), `pn` (name), `mc` (**MCC — free categorization, no API**), `am`.
- *Verify in build:* merchant QRs generally carry `mc`; P2P QRs won't. Fall back to VPA lookup → user pick.
- Hand off via `upi://pay?pa=...` Android intent, pre-filled.
- **iOS degraded** — no reliable `upi://` scheme. Scan+recommend works; user switches apps manually. **Android-first.**

**Critical rule — RuPay-only for UPI:** UPI credit-card payments work *only* with RuPay credit cards, and *only* at merchant QRs (never P2P). The engine must filter to RuPay on QR scans, detect P2P QRs and say *"credit card not usable here"*, and separately suggest the best physical card for counter payment. **Recommending a non-RuPay card for a QR = declined payment at the counter = instant trust death.**

### 4.2 Rules Engine + Card Management
- Add cards by issuer + product name — **never card numbers**.
- Full lifecycle: add, edit, archive (not delete — preserves history), reorder, set default.
- Category → ranked cards with expected ₹ value.
- **40–50 India cards at launch** (raised from 15–20; 500 users will hold a long tail, and "your card isn't supported" is a churn event).
- The app only needs the user's owned card list at the issuer/product level.
- It should not ask for or store PAN, CVV, expiry, PIN, or last 4 digits for the ranking flow.
- When location resolves to a known merchant or merchant category, the engine ranks only the cards already in that wallet and surfaces the best one.

### 4.3 Offline-First ⭐
Everything ships in local SQLite. QR scan → recommendation **never touches the network**. Every network-dependent feature has a defined offline behaviour and a visible sync state.

### 4.4 "Why This Card?" Transparency ⭐
Every recommendation shows its reasoning: *"5% on groceries · ₹2,300 of ₹5,000 monthly cap left · points worth ₹0.25 each."* Users don't trust a black box telling them how to spend money — and it makes bad data visible and reportable rather than silently corrosive.

### 4.5 Comparison View
Side-by-side of all cards for this merchant, not just the winner.

### 4.6 Manual Override ⭐ NEW — user intent beats the algorithm
*"Always use Card X here."* Users have reasons we can't model — EMI plans, expense reimbursement, a card they're deliberately spending down for a milestone. **A recommendation engine that can't be overridden is one users stop trusting.** Overrides are per-merchant and per-category, and always visible/reversible.

### 4.7 Manual Quick-Add
Under three taps: "spent ₹X at Y." Backstop for every tracking channel and for cash-adjacent cases.

### 4.8 Merchant Search
Typed lookup: "Amazon" → best card. Covers online and pre-trip planning.

---

## 5. Automatic Transaction Tracking ⭐⭐⭐

**Non-negotiable.** Cap, milestone, utilization and fee-waiver tracking are worthless without it. Built **redundantly** so no single external approval gates the product.

### 5.1 Channel 1 — SMS with Play Permissions Declaration (Android, zero friction)
Google Play operates a **Permissions Declaration Form** with explicit exceptions where the permission delivers core functionality, no alternative exists, and — named in policy — **SMS-based financial transactions**.

Our design is close to the strongest possible application: parsing is **100% on-device**, raw SMS never leaves the phone, and we extract only financial fields. Policy forbids "exfiltrating or sharing non-financial or personal SMS history" — **we do neither, by architecture.**

**Apply at the start of Phase 3.** Free. Many Indian finance apps run with this permission, so it's clearly obtainable. *Approval is not guaranteed — which is why Channel 2 is built in parallel, not after.*

### 5.2 Channel 2 — Email Forwarding ⭐ THE GUARANTEED PATH
**This is what ensures v1.0 ships with automatic tracking**, because it needs permission from nobody.

- User creates **one filter**: *from:(bank senders) → forward to their unique address on our domain.*
- We receive **only bank transaction mail** — never touch their inbox, never hold credentials, never request an OAuth scope.
- **No Google review, no CASA, no verification, no token expiry.**
- Works on **any provider**, and identically on **Android and iOS** — this is what finally solves iOS parity.
- **Privacy is genuinely better than OAuth:** with a Gmail token we *could* read everything; with forwarding we are structurally incapable of seeing anything else.
- **Setup:** ~3 minutes, one time. Per-provider screenshot walkthroughs; Gmail requires verifying the forwarding address once. **Never block first use on it.**

### 5.3 Channel 3 — IMAP with App Password (fallback)
Works today for personal Gmail with 2FA. **Fallback only** — Google has progressively restricted basic auth (Workspace already requires OAuth since March 2025, with further client sign-in restrictions announced for May 2026). Don't architect around it.

### 5.4 Statement PDF Import ⭐⭐ — the accuracy anchor
Password-protected PDF statements parsed **on-device**. Yields bank-confirmed ground truth: every transaction, exact points posted, closing balance. This is what flips estimates to confirmed. Password never stored, never uploaded.

### 5.5 SMS One-Time Bulk Import
Onboarding backfill from an SMS backup file — instant "here's what you've missed." Needs no special permission, independent of Channel 1.

### 5.6 Transaction Management
Production apps let users fix things: edit, delete, recategorize, split, mark as ignored (refunds, reversals, personal transfers), and search/filter. Parsers will occasionally be wrong — **the user must always be able to correct the record.**

### 5.7 Parser Failure Handling
When a bank message doesn't parse: queue it, surface it as *"1 transaction needs review,"* let the user fill it in with one tap, and log the pattern for a parser fix. **Never drop data silently.**

### 5.8 Duplicate Detection
The same transaction can arrive via SMS *and* email *and* statement. Deduplicate on (amount + merchant + date + card), with user-visible merge. Double-counting corrupts every cap and milestone downstream.

### 5.9 Rejected: Notification Listener
It's the permission pattern banking-fraud malware uses to intercept OTPs — requesting it invites Play enforcement *and* justified user suspicion.

### 5.10 Estimated vs Confirmed Labeling — non-negotiable
Every number carries visible state: **estimated** until reconciled against a statement, then **confirmed**.

### 5.11 Data Freshness Indicator
Each card's rules show *"verified March 2026."* Cheap honesty that makes staleness visible.

---

## 6. Our Crowdsourced Database ⭐⭐⭐ CORE INFRASTRUCTURE

### 6.1 Four datasets
1. **VPA → Merchant → Category** — `pa` is a globally unique, stable merchant key. Solves the long tail no static DB can.
2. **Merchant → Location** — a POI map weighted by *where people actually spend*. Feeds geofencing.
3. **Card Acceptance Data** ⭐ *nobody else has this.* One-tap *"Amex didn't work here."* Amex/Diners acceptance in India is unpredictable and **unmapped by any existing product.**
4. **Real Effective Reward Rates** — from statement reconciliation. Detects silent T&C changes.

### 6.2 Privacy architecture
- **Merchant records carry no user identity. Ever.** The row is about the *shop*, not the shopper.
- **No amounts, no individual timestamps** in shared records.
- **Coordinates grid-snapped (~50m) before upload.** We store *a shop exists near here*, never *a person was here*.
- **Contributions are decoupled from the user account** — even though v1.0 has authentication (§7), contributions are stripped of identity before storage. Auth exists for the user's benefit (sync, backup), never to attach identity to shared data.
- A crowdsourced financial dataset that leaked spending would end the product. **Anonymization is architectural, not a policy promise.**

### 6.3 Data quality gates
- **Confidence score** per record from independent confirmations.
- **Don't publish below N ≥ 2–3 independent agreements.**
- **Conflicts:** majority wins, weighted toward recency.
- **Abuse resistance (production requirement):** server-side rate limiting per device, anomaly detection on mass submissions, and **never trust client-supplied data without validation.** A poisoned merchant database produces wrong financial advice at scale.

### 6.4 Cold start — works from user #1
MCC arrives inside the QR itself, so category detection is perfect from the first scan with zero crowd. Bundled OSM covers major chains from install. Crowdsourcing *enhances*; it is never a prerequisite.

### 6.5 Build rule
**Instrument capture from the first QR scan shipped.** Data you didn't collect is gone forever.

---

## 7. Accounts, Sync & Data Ownership

Self-hosted authentication, and the design principle that makes it safe:

### 7.1 Authentication
- Self-hosted (PocketBase / Supabase / Appwrite — all include auth and are single-operator friendly).
- **Email + password, or passwordless email link.** Phone-OTP costs money per SMS; avoid at this stage.
- **Full lifecycle in v1.0:** signup, login, password reset, logout, session expiry, and **account deletion** (a DPDP requirement, §8).

### 7.2 Optional, not mandatory
**The app must be fully usable without an account.** Local-only mode is a first-class path. Auth unlocks sync/backup — it is never a gate on core function. This preserves the privacy positioning and removes a signup drop-off at first run.

### 7.3 Multi-Device Sync + Conflict Resolution
Real users have a phone and a tablet, or change phones. Offline edits on two devices *will* conflict. Define resolution explicitly (last-write-wins per field, with an append-only transaction log). **Silent data loss during sync is the fastest way to lose a finance-app user permanently.**

### 7.4 Backup & Restore
- Server-side automated backups with **tested restores** (an untested backup is not a backup).
- User-facing export/import so a user can leave with their data.

### 7.5 Data Export ⭐
One-tap CSV/JSON export of everything. Signals "your data is yours," and pre-empts the biggest objection to a finance app holding your history.

---

## 8. Legal & Compliance — v1.0 Scope, Not Later

This is the section most solo builders skip and most regret.

### 8.1 "Not financial advice" disclaimer ⭐ REQUIRED
The app recommends financial behaviour. Display a clear, persistent disclaimer that it provides **informational suggestions based on publicly available reward terms**, is **not a regulated financial advisor**, and that users should verify terms with their issuer. Google Play separately requires financial apps to state they aren't a regulated financial service unless they are.

### 8.2 India DPDP Act compliance ⭐ REQUIRED
The Digital Personal Data Protection Act imposes real obligations when handling Indian users' personal data:
- **Explicit, purpose-specific consent** — no bundled or implied consent.
- **Right to erasure** — account deletion must actually delete, including backups, within a stated window.
- **Right to access/correct** — served by export (§7.5) and transaction editing (§5.6).
- **Data minimisation** — collect only what's needed. Our architecture already does this; document it.
- **Breach notification** procedure defined *before* you need it.

### 8.3 Store compliance
Play Data Safety declarations must match actual behaviour exactly; privacy policy and terms hosted on your domain; target API level current.

### 8.4 Terms of Service + Privacy Policy
Written in plain language, covering: reward data may be inaccurate or stale, no liability for financial decisions, how crowdsourced contributions are used, and the anonymization guarantee.

---

## 9. Production Readiness — Non-Negotiable for 500 Users

The unglamorous work that separates a product from a demo.

### 9.1 Observability
- **Crash reporting** (Sentry free tier or self-hosted GlitchTip).
- **Structured server logs** with error alerting to your phone.
- **Uptime monitoring** — you find out before users do.

### 9.2 Remote control
- **Feature flags / remote config** — disable a broken feature without a store release (store review can take days).
- **Forced-upgrade mechanism** — for a critical bug or a breaking schema change.
- **Server-side kill switch** for the recommendation engine if bad card data ships.

### 9.3 Data integrity
- **Versioned schema migrations** on both device and server, tested both directions.
- **Automated backups with tested restores.**
- **Input validation server-side** — never trust the client.

### 9.4 Rate limiting & abuse
Per-device limits on contribution endpoints, anomaly detection, and API authentication. At 500 users this matters less for load than for **data poisoning**.

### 9.5 Support ⭐
- **In-app feedback** with automatic diagnostic context.
- A monitored support email.
- **In-app "report wrong reward data"** with a review queue — with 40–50 cards, users *will* find errors, and the reporting path is what converts an error from a trust loss into a trust win.

### 9.6 Quality states
Every screen needs **loading, empty, error, and offline** states. This is roughly 30–40% of real app work and is what makes software feel finished.

### 9.7 Notification discipline ⭐
Granular per-category controls, quiet hours, per-location snooze/mute, and a strict frequency cap. **Notification spam is the #1 uninstall driver for location-aware apps.** Default to conservative.

### 9.8 Accessibility & platform hygiene
Dynamic text scaling, sufficient contrast, screen-reader labels, dark mode. English at launch; architect strings for Hindi and regional languages later.

### 9.9 Onboarding
Production-quality first-run: what it does, why permissions are needed (in context, not upfront), add first cards, optional tracking setup, first scan. **Users must reach value before being asked for any permission.**

### 9.10 Pre-launch testing
Internal testing track → closed beta with 20–30 real users before opening to 500. Real Indian bank messages across issuers are the only way to validate parsers.

---

## 10. India-Specific High-Value Trackers

### 10.1 Cap & Limit Tracker ⭐⭐ THE KILLER FEATURE
*"You've used ₹4,700 of your ₹5,000 SBI Cashback cap — switch to Card B."* Once a cap is hit, the best card changes. No static-table competitor can do this.

### 10.2 Credit Utilization Optimizer ⭐⭐ genuinely novel
Utilization is ~30% of a credit score, and scores matter enormously in India. *"This ₹40,000 purchase pushes this card to 68% — split it to stay under 30%."* Pure arithmetic, zero data cost, completely unserved.

### 10.3 Multi-Card Split Suggestion
Split large purchases to stay under reward caps *and* utilization thresholds simultaneously.

### 10.4 Milestone Spend Tracker ⭐⭐
*"₹22,000 more on Atlas unlocks the ₹10,000 voucher"* — can legitimately flip a recommendation toward a worse base rate.

### 10.5 Annual Fee Waiver Tracker ⭐⭐
*"Spend ₹38,000 more before 14 March to waive your ₹10,000 fee."* Common, infuriating, entirely preventable loss.

### 10.6 Billing Cycle / Float Optimizer
*"Card A's statement just generated — ~50 interest-free days vs 21 on Card B."*

### 10.7 UPI-vs-Swipe Comparison ⭐ India-specific
Two rails at the same counter: *"Scan-and-pay earns 1%; swiping your Amex earns 5% — swipe instead."*

### 10.8 Backup Card / Acceptance
Always show **primary + backup** — Amex/Diners acceptance is patchy, RuPay-only applies to UPI QR.

### 10.9 Forex Markup / Travel Mode
Markups range ~0%–3.5%. Surfaces lowest-markup card, flags DCC traps.

### 10.10 Fuel Surcharge Waiver Tracker
1% surcharge waived up to a monthly cap. Same machinery as 10.1.

### 10.11 Lounge Access Tracker
*"6 of 8 domestic visits used this quarter."* High value for the premium segment.

### 10.12 Point Expiry & Bill Due Alerts + Due-Date Calendar
Table stakes, expected, cheap.

### 10.13 EMI Trap Advisor
*"Converting to EMI costs ~₹4,200 interest and forfeits the 5% cashback."*

### 10.14 Card Benefits Cheat Sheet
Offline reference of forgotten perks — insurance, extended warranty, concierge, golf. Static data, genuinely useful.

### 10.15 Big-Purchase Calculator
Amount + category → side-by-side ₹ value across all cards, factoring caps and milestones.

---

## 11. Location (₹0, no paid API)

### 11.1 Zero-Cost Merchant Location
1. **Bundled OSM extract.** Geofabrik's free India extract, filtered offline (osmium) to retail POIs → **few-MB SQLite shipped in-app.** Zero API calls forever, works offline.
   - **Licence:** ODbL — attribution required, share-alike on derived databases. Plan to publish the filtered extract under ODbL.
2. **Own crowdsourced data** (§6) — better than any vendor for this purpose.
3. **One-tap user labeling** for unknowns.

**Category beats brand:** the engine needs "supermarket" / "fuel station", not "DMart Powai". OSM tags give exactly that. Brand precision only matters for merchant-specific offers (Part II).

**Explicitly rejected — scraping Google Maps.** A `geo:` intent only *displays* a map and returns no data; there's no mechanism to bill Places against a user's personal account. Google's ToS prohibits automated access without written permission — scraping risks IP blocking, Play removal, and civil liability. **For an app selling financial trust, being caught scraping is an extinction-level event.**

**If a paid API is ever added:** cache **server-side, never per-device**, converting an unbounded per-user cost into a bounded, decaying one.

### 11.2 Geofence Notifications
**Geofencing, never continuous GPS.** Minimal permission scope, in-context explanation, and full usability if denied.

### 11.3 Home Screen = One Answer
*"Your best card right now: X"* plus a prominent **Scan** button. Not a dashboard. Plus home-screen widget and Android Quick Settings tile.
- If the app recognizes the current place, this becomes a place-aware answer like *"You're at a petrol pump - use Card X."*

---

## 12. Retention & Trust

### 12.1 Monthly Savings Report ⭐⭐
*"This month you earned ₹3,240 extra by following recommendations — ₹610 more was available."* Answers "is this worth keeping?" with a number. Strongest retention and word-of-mouth lever, costs nothing to compute.

### 12.2 Missed Opportunity Log
Habit correction, not just lookup.

### 12.3 Card Portfolio Audit
*"You paid ₹5,000/year for this card and used it twice."*

### 12.4 Emergency Card Info
Offline lost-card hotlines and block procedures per issuer. Tiny effort, disproportionate goodwill in a panic.

---

## 13. Technical Architecture (self-hosted)

| Layer | Choice | Notes |
|---|---|---|
| App | **Flutter**, Android-first | Tooling already present. |
| Local store | **SQLite** (`drift`) | Source of truth on device; offline-first. |
| Backend + Auth | **Self-hosted PocketBase or Supabase** on a VPS | Both include auth, DB, storage, realtime. Single-operator friendly. |
| Database | **Postgres** (Supabase) or SQLite (PocketBase) | Automated backups mandatory. |
| Edge / CDN | **Cloudflare free tier** | DDoS protection, caching, TLS. |
| Email ingest | **Cloudflare Email Routing → Worker** (free) | Receives forwarded bank mail. No OAuth. |
| QR | `mobile_scanner` | Free, no license. |
| UPI handoff | `upi://pay` Android intent | Free, no TPAP. |
| POI data | Bundled filtered OSM + crowdsourced | Zero API calls. |
| Geofencing | OS geofence APIs | Never continuous GPS. |
| PDF statements | `syncfusion_flutter_pdf` or equivalent | On-device; password never stored. |
| Crash reporting | Sentry free tier / self-hosted GlitchTip | Non-negotiable at 500 users. |
| Widget / tile | Native Android App Widget + Quick Settings tile | Small native modules. |

**Where AI does the heavy lifting:** Flutter screens and state management, QR + UPI intent logic, SMS/email/PDF parsers, SQLite schema and migrations, backend API and auth wiring, and — most valuably — **first-pass structured extraction of card reward rules from bank T&C pages** for you to verify. You own: verifying reward data against source, device testing, production operations, and product calls.

---

## 14. Data Plan

1. **Your own cards** — hand-verified.
2. **40–50 India cards** — AI-assisted extraction from official T&C pages, **you verify every one**. This is the largest single data task; budget for it honestly.
3. **In the same pass capture everything §10 needs:** caps, milestone thresholds, fee-waiver spend, lounge quotas, forex markups, fuel surcharge caps, benefits, billing cycle rules. **Collect once per card, not five times.**
4. **Merchant categories** — free via QR `mc`; bundled OSM for chains; long tail via crowdsourcing.
5. **Bank message formats** — collect real samples per issuer during closed beta; this is what parser accuracy depends on.
6. **Redemption values** — monthly manual spot-check.

---

## 15. Costs

| Item | Cost |
|---|---|
| Play/App Store accounts, domain | **Already owned** |
| **VPS hosting** (backend + auth + DB) | **~₹500–1,500/month** — comfortably handles 500 users |
| Cloudflare (CDN, email routing) | **₹0** free tier |
| POI / location data | **₹0** bundled OSM |
| QR + UPI intent | **₹0** |
| PDF / SMS parsing | **₹0** on-device |
| Crash reporting | **₹0** free tier |
| Card rules data | **₹0** — your time + AI extraction |

**Recurring: ~₹500–1,500/month for hosting.** Everything else is free. No per-user API costs at any scale.

---

## 16. Roadmap to v1.0

Production quality takes longer than a demo. Honest estimates for solo + AI pairing:

| Phase | Scope | Effort |
|---|---|---|
| 1 | Rules engine, card management, offline SQLite, "why this card", comparison view, manual override; **40–50 cards with all §10 data captured and verified** | 5–7 wks |
| 2 | **QR scan → recommend → UPI handoff** + RuPay filtering + crowdsource capture instrumented | 3 wks |
| 3 | **Tracking: email-forwarding pipeline + SMS declaration application + statement PDF import + SMS bulk import** + dedup + parser-failure queue + transaction management | 4–5 wks |
| 4 | Cap, utilization, milestone, fee-waiver, billing-cycle trackers | 3 wks |
| 5 | Self-hosted backend + auth + multi-device sync + conflict resolution + backups | 3–4 wks |
| 6 | Bundled OSM + geofence notifications + notification controls + widget + Quick Settings tile | 4 wks |
| 7 | Crowdsource sync + confidence scoring + rate limiting + abuse resistance | 2–3 wks |
| 8 | Savings report, benefits sheet, travel mode, EMI advisor, export, emergency info, portfolio audit | 3 wks |
| 9 | **Production hardening:** observability, feature flags, forced upgrade, migrations, all loading/empty/error states, accessibility, onboarding | 3–4 wks |
| 10 | **Legal + compliance:** DPDP consent flows, deletion, disclaimers, ToS/privacy policy, Play data-safety | 1–2 wks |
| 11 | **Closed beta (20–30 users)** — parser validation against real bank messages, bug fixing | 3–4 wks |

**Realistic total: ~8–10 months solo** to a genuinely production-ready v1.0 for 500 users.

**Start on day 1** (both free, both slow, neither blocking): the **Play SMS Permissions Declaration**, and **Google OAuth verification** for the Part II upgrade.

**Sequencing note:** Phases 1–4 produce a working, useful app you can dogfood daily. Do not skip Phases 9–11 to launch sooner — for a financial app, they *are* the product.

---

## 17. Privacy & Trust

- **Account optional.** Full local-only mode; auth exists for sync/backup, never as a gate.
- **Crowdsource contributions decoupled from identity** even for logged-in users.
- **Statements:** PDF password on-device, never transmitted or stored.
- **SMS:** parsed on-device, raw content never leaves the phone.
- **Location:** geofencing only; app fully usable if denied.
- **Cards:** issuer + product name only — **never full card numbers**.
- **Never:** credential-based bank scraping, stored bank passwords, Notification Listener.
- **Encryption:** at rest on device for financial data; TLS everywhere; no secrets in the client.

In this category a privacy misstep isn't a bug, it's an extinction event. The permission set must be defensible to a suspicious user reading the Play listing.

---

## 18. Honest Risks

- **Card data accuracy is the core operational risk.** 40–50 cards × many fields, hand-verified, drifting constantly. The in-app error-reporting path (§9.5) and freshness indicators (§5.11) are what keep errors survivable.
- **Parser fragility.** Every bank formats messages differently and changes them without notice. The failure queue (§5.7) must never silently drop data. Closed beta exists primarily to harden this.
- **SMS declaration may be rejected** — Google could argue an alternative exists, which our own redundancy hands them. Treat approval as upside, never as the plan.
- **Email-forwarding setup friction (~3 min)** will lose some users. Mitigate with walkthroughs; never block first use.
- **Sync conflicts** are the classic multi-device data-loss vector. Design resolution before writing sync code.
- **QR `mc` coverage unverified in the wild** — validate with real scans early in Phase 2.
- **OSM India coverage** is strong in metros, patchy in smaller towns.
- **iOS materially degraded** (no UPI intent, no SMS) — Android-first is a strategic constraint.
- **Solo operational load.** 500 users generate support, incidents, and data-maintenance work continuously. Monitoring and kill switches are what make that survivable.
- **Scope creep is the most likely cause of failure.** The §10 tracker list is endlessly expandable. Ship the roadmap, then listen to users.

---

# PART II — FUTURE (Post-v1.0)

## 19. Blocked on External Approval

### 19.1 Gmail OAuth — a UX upgrade, not a missing capability
Automatic tracking already ships in v1.0 via email forwarding. OAuth would replace a ~3-minute one-time setup with a single sign-in tap.
- **Blockers:** completed verification, and Gmail read scopes are *restricted* tier → **CASA security assessment**, real money.
- **Worth noting:** forwarding is *more* privacy-preserving. This trades a better privacy story for lower friction — not obviously worth it until users ask.

### 19.2 Account Aggregator (AA)
RBI-regulated consent-based data sharing (2.88B accounts enabled as of March 2026; Sahamati is SRO). Would replace parsing with an official feed. **Blocker:** FIU registration, realistically requiring an established company. Verify whether reward-*points* balance is even a supported AA data type before investing.

### 19.3 In-App UPI Payment (TPAP)
Removes the app-switch entirely. **Blocker:** company + sponsor PSP bank + NPCI approval + audits + data localization.

## 20. Needs Scale

### 20.1 Empirical Rate Learning
Infer *real* effective rates statistically from (transaction → confirmed points) pairs. Self-corrects silent T&C changes. Needs a user base to be meaningful.

### 20.2 Community Data Correction at Scale
Beyond v1.0's report-an-error queue: reputation weighting, automated consensus. Pointless at 500 users, essential at 50,000.

### 20.3 Acceptance Map as a Licensable Asset
Valuable only with density.

## 21. Costs Money / Ongoing Burden

### 21.1 Merchant-Specific Bank Offers
*"10% off on Amazon with HDFC this week."* Scrapeable, but **continuous maintenance** is the real cost.

### 21.2 Paid POI Fallback
Photon (free, no key), Geoapify, LocationIQ, Foursquare free tiers before ever considering Google Places. Server-side cache mandatory.

### 21.3 iOS Full Parity
WidgetKit, manual UPI switch, no SMS path. Worth doing once Android proves the model.

### 21.4 Localization
Hindi and regional languages. Architect strings for it in v1.0; translate later.

## 22. Bigger Product Bets

### 22.1 Browser Extension — online-checkout equivalent of the QR scan.
### 22.2 Spend Simulator + Referral Monetization — model a candidate card against **actual** 12-month spend; natural home for card-application referral revenue.
### 22.3 Redemption Advisor — *"50,000 points: ~₹15,000 via transfer vs ~₹5,000 as credit."* Needs a maintained redemption dataset.
### 22.4 Family / Shared Card Pool — post-traction.
### 22.5 Predictive Recommendations — *"you usually buy groceries Saturday morning."*
### 22.6 Insurance & Warranty Claim Helper — cards include free coverage almost nobody claims; guided claims would be highly differentiated but need per-issuer research.

## 23. Monetization (Future)

- **Referral/affiliate on card applications** via the spend simulator — strongest early revenue, credible because grounded in real spend.
- **Freemium subscription** (~₹500–1,000/yr) for advanced trackers, multi-card portfolios, travel mode.
- **Anonymized aggregate insights** — approach cautiously; inconsistent with the trust positioning if handled carelessly.

**Nothing in v1.0 should be paywalled.** Prove value with the savings report first; monetize once retention is real.
## Current place-aware recommendation behavior

- Card recommendations are location-context aware across any merchant/place, not tied to a "home" location.
- The app resolves the best card using the nearest merchant candidate's category first, then merchant display name when available.
- Merchant-name overrides take precedence over broader category overrides when both match the same place.
- Background geofence alerts and foreground merchant screens use the same shared recommendation path, so they cannot drift apart.
- Merchant/category overrides are resolved against the user's owned cards before ranking, which keeps the suggestion aligned with the place the user is actually in.
- The app still does not ingest or require PAN, CVV, expiry, PIN, or other sensitive card numbers for this flow.
