# PandaPay — Complete UI Specification (v1.0 Production)

Companion to `product-plan.md`. Together these two documents are intended to be **sufficient to implement the entire application** — the plan defines *what and why*, this defines *where and how*.

**Total: 66 screens + 6 system surfaces.**

Each screen below specifies: **Purpose · Data displayed (and its source) · Features (numbered, with logic) · Actions · Edge cases · States.**

---

## 0. Feature → Screen Traceability Matrix

Every feature in the plan maps to at least one screen. No orphans.

| Plan § | Feature | Screen(s) |
|---|---|---|
| 3 | Core loop (scan → learn → passive) | B1, B2, B3, S3 |
| 4.1 | QR scan → UPI handoff | B2, B3 |
| 4.1 | RuPay-only UPI rule | B3 |
| 4.2 | Rules engine, card management | C1, C2, C3, C4 |
| 4.3 | Offline-first | All (S4) |
| 4.4 | "Why this card?" | B1, B3, B4 |
| 4.5 | Comparison view | B4 |
| 4.6 | Manual override | B3 (create), **B8 (manage)** |
| 4.7 | Manual quick-add | B6 |
| 4.8 | Merchant search | B5 |
| 5.1 | SMS auto-read (declaration) | F4 |
| 5.2 | Email forwarding | F3 |
| 5.3 | IMAP fallback | **F7** |
| 5.4 | Statement PDF import | F2 |
| 5.5 | SMS bulk import | F4 |
| 5.6 | Transaction management | D1, D2, D3 |
| 5.7 | Parser failure queue | D4 |
| 5.8 | Duplicate detection | D5 |
| 5.10 | Estimated/confirmed labels | All financial figures |
| 5.11 | Data freshness | C2, C7 |
| 6.1 | VPA/merchant/category capture | B3 (auto + correction) |
| 6.1 | Card acceptance data | B3 ("wasn't accepted") |
| 6.1 | Effective rate learning input | F2 (reconciliation) |
| 6.2 | Contribution privacy / opt-out | H4, **E12** |
| 7.1 | Auth lifecycle | A4, A5, A6, H2 |
| 7.2 | Optional account | A3 |
| 7.3 | Sync + conflict resolution | F5 |
| 7.4 | Backup & restore | F5 |
| 7.5 | Data export | F6 |
| 8.1 | Not-financial-advice disclaimer | A2, H8, E3 |
| 8.2 | DPDP consent + erasure | A4, H2, H4 |
| 9.5 | Support + error reporting | C7, H9 |
| 9.7 | Notification discipline | H3 |
| 9.9 | Onboarding | A1–A11 |
| 10.1 | Cap tracker | E2, B1, B3 |
| 10.2 | Credit utilization | E3 |
| 10.3 | Multi-card split | G2, B7 |
| 10.4 | Milestones | E4 |
| 10.5 | Fee waiver | E5 |
| 10.6 | Billing cycle / float | E7 |
| 10.7 | UPI-vs-swipe | B3 |
| 10.8 | Backup card / acceptance | B1, B3 |
| 10.9 | Forex / travel mode | G1 |
| 10.10 | Fuel surcharge waiver | E2 (cap type) |
| 10.11 | Lounge tracker | E6 |
| 10.12 | Points expiry, bill due | C6, E8 |
| 10.13 | EMI advisor | G3 |
| 10.14 | Benefits cheat sheet | C5 |
| 10.15 | Big-purchase calculator | B7 |
| 11.1 | Bundled OSM / location | B1, H5 |
| 11.2 | Geofence notifications | S3, H3 |
| 11.3 | Home = one answer | B1, S1, S2 |
| 12.1 | Monthly savings report | E9 |
| 12.2 | Missed opportunities | D6 |
| 12.3 | Portfolio audit | E10 |
| 12.4 | Emergency card info | G4 |
| 9.2 | Forced upgrade / kill switch | S5, S6 |
| — | Changelog after update | **H10** |

---

## 1. Navigation Architecture

```
┌──────────────────────────────────────────────┐
│                 SCREEN BODY                  │
├──────────────────────────────────────────────┤
│  Home    Cards   ( SCAN )   Activity   More  │
└──────────────────────────────────────────────┘
```

- **Centre SCAN is a raised FAB**, not a tab — the highest-value action, one thumb-tap from anywhere.
- Max **3 levels deep** from any tab root.
- Deep links required for: scan result, transaction detail, card detail, every tracker, needs-review queue.

**Tab contents:**
- **Home** → B1
- **Cards** → C1
- **Activity** → D1 (with badge for D4 count)
- **More** → E1 hub + G tools + H settings

---

# GROUP A — Onboarding & Auth (11 screens)

**Principle: value before permissions.** No permission prompt before A10.

### A1. Splash
**Purpose:** session/migration check.
**Features:**
1. Run pending DB migrations; show progress if >1s.
2. Validate session token; refresh silently if expired.
3. Check minimum supported version → route to S5 if below.
**Edge cases:** backend unreachable → proceed offline, never block. Migration failure → recovery screen offering restore from backup.
**Timing:** max 1.5s before routing.

### A2. Welcome
**Features:**
1. Headline: *"Know which card to use — before you pay."*
2. Three value points: scan any QR · automatic tracking · never miss a reward cap.
3. **Not-financial-advice disclaimer** in footer (small but present from first screen).
**Actions:** Get Started → A3 · I have an account → A5.

### A3. Account Choice ⭐
**Features:**
1. Two options with plain-language consequences:
   - **Use without an account** (recommended badge) — "Everything stays on this phone. Nothing is uploaded."
   - **Create account** — "Sync across devices and restore if you lose your phone."
2. Local mode must be genuinely first-class — no dark patterns, no nagging later.
**Edge case:** user in local mode can upgrade to an account any time via H2 without data loss (local data migrates up).

### A4. Sign Up
**Features:**
1. Email + password, or passwordless email link (preferred).
2. Password rules shown before submission; strength meter; show/hide.
3. **DPDP consent — separate, purpose-specific checkboxes, never bundled:**
   - (required) Accept Terms + Privacy Policy
   - (optional) Contribute anonymized merchant data to improve the app
   - (optional) Product update emails
4. Consent timestamp + version stored for audit.
**Validation:** email format, password min length, duplicate account.
**Errors:** network failure preserves entered data.

### A5. Log In
**Features:** email+password / magic link; biometric unlock offer after first success.
**Errors:** wrong credentials (generic message — don't reveal whether the email exists), unverified email, rate-limited, offline.

### A6. Password Reset
**Features:** email → sent-confirmation → deep-linked new password. Token expiry handled with a clear re-request path.

### A7. Add Your First Card
**Data source:** bundled card catalogue (40–50 cards).
**Features:**
1. Search by issuer or product name; grouped by issuer; card art thumbnails.
2. Multi-select with running count.
3. Filter chips: RuPay · Visa · Mastercard · Amex/Diners.
4. Copy: *"Add every card you own — the advice is only as good as what it knows about."*
5. **"My card isn't listed"** → A8.
**Validation:** cannot proceed with 0 cards.
**Edge case:** duplicate product added twice (user has two of the same card) → allow, differentiate by nickname.

### A8. Request Unsupported Card
**Features:** issuer + product name + optional photo of card **face only** (explicitly warn: never photograph the number). Submits to data backlog. Sets expectation of a future update.

### A9. Card Details Setup
Per added card, collect tracker inputs — **each field states why it's needed, all skippable except nickname when duplicated.**
**Fields:**
1. Nickname (auto-suggested).
2. Credit limit — *"used to protect your credit score"* (E3).
3. Statement generation date — *"used to maximise interest-free days"* (E7).
4. Payment due date — *"for bill reminders"* (E8).
5. Current points balance — *"starting point; we'll track from here"* (C6).
6. Current cycle spend, if known — improves cap accuracy immediately (E2).
**Edge case:** skipping limit disables E3 for that card with an inline explanation, not a silent gap.

### A10. Tracking Setup
**Features:**
1. Explains three channels with honest trade-offs:
   - **Email forwarding** — works on any phone/provider, ~3 min setup → F3
   - **SMS auto-read** — Android only, instant, on-device (shown only if declaration approved) → F4
   - **Manual / statement import** — no setup → F2
2. Recommends based on platform.
3. **"Set up later"** always visible.
**Edge case:** never block onboarding completion on this.

### A11. First Scan Tutorial
**Features:** animated demo, then live camera with overlay guide; success → B3; **Skip** → B1.

---

# GROUP B — Home & Recommendation (8 screens)

### B1. Home ⭐ MOST IMPORTANT SCREEN
**Purpose:** answer "which card?" in under 500ms, with zero input where possible.

**Data sources:** current geofence match (local POI DB + crowdsourced), user's cards, live cap/milestone state, manual overrides.

**Features (top to bottom):**
1. **Context line** — *"You're at DMart Powai"* · *"Near Indian Oil"* · *"Pick a category"*. Tappable to correct location.
2. **HERO recommendation card** — card art, name, reward in plain terms: *"5% cashback · about ₹120 on ₹2,400"*. Estimated/confirmed badge.
3. **"Why this card?"** — expandable, showing full arithmetic:
   - base rate for this category
   - cap remaining this cycle
   - point value used (₹/point)
   - milestone contribution, if it affects ranking
   - any active manual override (with an "override active" chip)
4. **Backup card row** — *"If not accepted: HDFC Regalia (2%)"*. Populated from crowdsourced acceptance data where available.
5. **Category chips** — Groceries · Fuel · Dining · Online · Travel · Bills. One tap re-ranks; overrides geofence guess.
6. **Alerts strip** — shown only when actionable, max 2 at once, priority-ordered:
   cap nearly hit > fee-waiver deadline > points expiring > bill due > needs-review count.
7. **SCAN button** (also the nav FAB).

**Ranking logic (must be implemented exactly):**
```
for each card:
  if UPI-QR context and card is not RuPay → exclude (show greyed)
  effective_rate = category_rate × point_value
  if cap_remaining < transaction_amount → blend capped and post-cap rates
  add milestone_bonus_value if this spend materially advances a milestone
  subtract forex_markup if travel mode
  apply manual override → force to top with "override" label
rank by expected ₹ value
```

**States:**
- No location permission → chips primary, no nag.
- Unknown location → *"Not sure where you are — scan or pick a category."*
- Offline → fully functional, subtle offline chip.
- No cards → single CTA to C3.
- Cold start → skeleton, never blank.

### B2. QR Scanner
**Features:**
1. Full-screen camera, framing guide, torch toggle.
2. **Gallery import** — scan a QR from a screenshot (common for online/UPI-link payments).
3. Auto-detect and decode; haptic on success.
4. Works fully offline.
**Edge cases:** non-UPI QR → *"That's not a UPI code"*; unreadable → hint to steady/clean lens; permission denied → explainer + settings deep link.

### B3. Scan Result ⭐
**Data captured on scan:** `pa`, `pn`, `mc`, `am`, device coordinates (grid-snapped before any upload).

**Features:**
1. Merchant name + detected category, **both editable** — corrections feed the crowdsource DB (§6.1).
2. Amount — pre-filled from `am` if present, else editable numeric entry.
3. **Ranked card list**, best first: card · rate · ₹ value · cap status · reason chip.
4. **RuPay/UPI eligibility, explicit:**
   - Non-RuPay cards greyed with *"Not usable via UPI — swipe this instead."*
   - P2P QR detected (no `mc`, personal VPA pattern) → *"Credit cards can't be used for personal transfers"* + suggest bank-account UPI.
5. **UPI-vs-swipe comparison** when both viable: *"Scan-and-pay earns 1% · swiping your Amex earns 5%."*
6. **"Pay with [card]"** → builds `upi://pay?pa=&pn=&am=&cu=INR` intent and launches the user's UPI app. **User never rescans.**
7. **"Always use this card here"** → creates a manual override keyed to VPA (→ B8).
8. **"This card wasn't accepted"** → records acceptance data, re-ranks immediately.
9. Silent background: contribute `{vpa, name, mcc, grid-coords}` if contribution consent is on.

**Edge cases:** `mc` absent → look up VPA in crowdsource DB → else ask user to pick a category (one tap, then remembered). No UPI app installed → show recommendation only, with a copy-VPA action.

### B4. Comparison View
**Features:** full sortable table — card · rate · ₹ value · cap remaining · milestone impact · forex · acceptance note. Each row expandable to its own "why". Reachable from B1 and B3.

### B5. Merchant Search
**Features:** typed search over bundled + crowdsourced merchants; recent searches; category fallback when no match; result → B3-style recommendation without a scan.

### B6. Manual Quick-Add
**Under 3 taps.**
**Features:** amount (keypad auto-focused) · merchant (autocomplete, remembers) · card (defaults to last used) · category (auto-filled from merchant) · date (today) · optional note.
**On save:** update caps/milestones/utilization immediately; undo snackbar.
**Validation:** amount > 0; future dates warn.

### B7. Big-Purchase Calculator
**Features:**
1. Amount + category input.
2. Side-by-side ₹ value across all cards, factoring caps, milestones, utilization impact.
3. **Split suggestion** → G2.
4. **EMI comparison** inline → G3.
5. Flags: *"This purchase alone completes your Atlas milestone."*

### B8. Manual Overrides ⭐ (was missing)
**Purpose:** view and manage every "always use X here" rule.
**Features:** list of overrides (merchant/category → card), created date, edit, delete, temporarily disable. Empty state explains how to create one from B3.
**Why it matters:** an override the user forgot about, silently producing worse advice, is a trust bug.

---

# GROUP C — Cards (8 screens)

### C1. My Cards
**Features:** card-art list, drag to reorder priority; per card — nickname, points balance, cap usage bar, utilization bar, next due date. Filter active/archived. FAB → C3.

### C2. Card Detail — tabbed
1. **Rewards** — full earn structure by category + **data-freshness date** ("verified March 2026").
2. **Caps** — each cap, usage this cycle, reset date, progress bar.
3. **Milestones** — progress, ₹ remaining, deadline, reward at stake.
4. **Fees** — annual fee, waiver threshold, progress, renewal date.
5. **Benefits** — lounge quota/usage, insurance, warranty, fuel surcharge, concierge.
6. **Statement** — cycle dates, due date, current float window.
**Actions:** edit (C4) · archive · **report wrong data** (C7).

### C3. Add Card — same picker as A7.

### C4. Edit Card
**Fields:** nickname, credit limit, statement/due dates, points balance, card art/colour.
**Archive** (never hard-delete with history) — explains history is preserved.

### C5. Benefits Cheat Sheet
Cross-card view of everything owned, grouped by benefit type (lounge · insurance · warranty · dining · fuel · golf). Offline, static. Answers *"what am I actually paying for?"*

### C6. Points & Expiry
Per-program balances, estimated ₹ value, expiry dates with urgency colouring, redemption hint, estimated/confirmed badges. Manual balance correction (feeds reconciliation).

### C7. Report Wrong Data ⭐
Pre-filled card + field · what we show · what it should be · optional source link/screenshot. Confirmation sets expectation: *"We verify before publishing."*

### C8. Request New Card — as A8, available any time.

---

# GROUP D — Transactions (6 screens)

### D1. Transaction List
**Features:** reverse-chronological, date-grouped. Row: merchant · amount · card · points (est/confirmed) · optimality indicator (✓ best / ⚠ better existed). Search + filters (date, card, category, source, needs-review). Sticky month summary: spend · points · missed value. **Badge for D4 count.**

### D2. Transaction Detail
Full record incl. source (SMS/email/statement/manual) and reconciliation status. **"A better card existed"** panel with which and how much. Actions: edit · recategorize · split · mark ignored (refund/reversal/transfer) · delete.

### D3. Edit Transaction
All fields editable; explicit save/cancel; changes logged; recomputes caps/milestones on save.

### D4. Needs Review Queue ⭐
Unparsed messages with **raw text shown** for context; one-tap fill of missing fields; **"Not a transaction"** dismiss (teaches the parser); bulk dismiss. **Never silently drop data.**

### D5. Duplicate Review
Side-by-side suspected duplicates (same amount+merchant+date across channels). Merge / keep both / delete one. Explains why they're flagged.

### D6. Missed Opportunities
Only sub-optimal transactions: used vs. better card, ₹ lost, running 90-day total. Filter by card/category to reveal patterns.

---

# GROUP E — Trackers & Insights (12 screens)

### E1. Insights Hub
Tile grid, each with a live headline number, priority-ordered by urgency (nearest deadline first).

### E2. Caps & Limits ⭐
All capped benefits across cards (**including fuel-surcharge caps**, §10.10), progress bars, reset dates, sorted by closest-to-cap. Actionable copy: *"₹300 left on SBI 5% — switch to Axis Ace after that."*

### E3. Credit Utilization ⭐
Per-card + overall utilization bars, colour-coded at the 30% threshold, plain-language explanation, **"Optimize"** → redistribution suggestion. **Explicit disclaimer: informational, not a credit-score guarantee.**
**Edge case:** cards without a limit entered are excluded, with a prompt to add it.

### E4. Milestones — progress, ₹ remaining, days left, reward at stake; flags when chasing beats base rate.
### E5. Annual Fee Waivers — fee, threshold, progress, days to anniversary, urgency colouring.
### E6. Lounge Access — visits used vs quota per network/card, quarter reset, **manual "log a visit"** (banks rarely message this).
### E7. Billing Cycle / Float — timeline per card; *"Use Card A today → 48 interest-free days."*
### E8. Due Date Calendar — month view of statement + due dates, amounts where known, per-card reminder toggles.

### E9. Monthly Savings Report ⭐⭐
Headline ₹ earned extra · breakdown (earned / extra vs single-card baseline / value missed) · category breakdown · best card · month-over-month trend · **share as image**.
**Edge case:** first month has no baseline — show "building your first report" rather than a misleading zero.

### E10. Portfolio Audit — per card: annual fee vs rewards earned, break-even, usage frequency, unused benefits.
### E11. Spending Overview — category/merchant breakdown by month; context, not a budgeting tool.

### E12. My Contributions ⭐ (was missing)
**Purpose:** make the crowdsource loop visible and opt-out real.
**Features:** count of merchants mapped/confirmed by this user, *"you've helped X other users"*, contribution toggle (mirrors H4), and a plain restatement of exactly what is shared (never identity, amounts, or exact location).

---

# GROUP F — Data Import & Sync (7 screens)

### F1. Import Hub — status card per channel (active / not set up / error) → F2–F4, F7.

### F2. Statement PDF Import
File picker → password prompt (*"processed on your device, never uploaded"*) → parse progress → **preview of detected transactions** → duplicate check → confirm import. On success, reconciles estimates to **confirmed** and updates point balances.
**Errors:** wrong password · unsupported issuer format · corrupt file — each with a next step and a "report this format" action.

### F3. Email Forwarding Setup ⭐ highest-friction flow
1. Unique forwarding address with copy button.
2. **Provider-specific step-by-step with screenshots**: Gmail · Outlook · Yahoo · Other.
3. Explicit handling of Gmail's forwarding-address verification (we send the code; user pastes it).
4. **Live status:** *"Waiting for first email…"* → *"Connected — 3 received."*
5. Troubleshooting + test-email action.
6. Skippable at any point.

### F4. SMS Import
One-time backup-file import (always available) + auto-read toggle (Android, only if declaration approved) with on-device parsing explanation.

### F5. Sync & Backup
Last sync, pending changes, manual sync. **Conflict log — never resolve silently without a record.** Backup status, restore entry point (destructive, double-confirmed).

### F6. Data Export
Scope (transactions/cards/all) + format (CSV/JSON) → generate → share. Copy: *"Your data is yours."*

### F7. IMAP Connection (fallback) ⭐ (was missing)
For users who prefer it over forwarding. Email + **app password** (with a link explaining how to generate one), server auto-detection, sender-filter configuration, test connection.
**Must warn:** Google is progressively restricting basic auth; if it breaks, fall back to F3.

---

# GROUP G — Tools & Modes (4 screens)

### G1. Travel Mode — toggle re-ranks by forex markup; per-card markup comparison, lounge eligibility, travel insurance, **DCC warning explainer**, destination acceptance notes.
### G2. Multi-Card Split Planner — total amount → optimal split respecting caps + utilization; visual allocation with per-card reward totals.
### G3. EMI Advisor — amount, tenure, rate → total interest, effective cost, **rewards forfeited**, verdict line.
### G4. Emergency Card Info — per-issuer lost-card hotline, block procedure, international collect number, one-tap dial. **Works with zero network and zero login.**

---

# GROUP H — Settings & Account (10 screens)

### H1. Settings Hub — Account · Notifications · Privacy & Permissions · Data · Appearance · Help · About.

### H2. Account
Email, sign-out, upgrade-from-local-mode, biometric lock toggle.
**Delete account** — states exactly what is deleted and by when (incl. backups), typed confirmation, grace period. **DPDP requirement.**

### H3. Notification Settings ⭐ uninstall-prevention
Per-category toggles (location · caps · milestones · fee waivers · bills · expiry · monthly report · needs-review) · **per-merchant mute list** · **quiet hours** · **daily frequency cap**. Conservative defaults.

### H4. Privacy & Permissions
Each permission: state, purpose, settings deep link. Plain-language data-handling summary (on-device vs uploaded vs anonymized). **Crowdsource contribution toggle — opt-out honoured immediately.** Consent history with timestamps (DPDP).

### H5. Data & Storage — storage used, cache clear, record counts, re-download bundled POI data, **reset all data** (destructive, double-confirmed).

### H6. Appearance — theme, text size, card art style, number format (lakh/crore).

### H7. Help & FAQ — searchable, offline-readable: setup, tracking channels, why a recommendation looked wrong, accuracy, privacy.

### H8. Legal — Terms · Privacy Policy · **Not-financial-advice disclaimer** · open-source licences · **OpenStreetMap ODbL attribution**.

### H9. Feedback & Support ⭐
Free-text + optional diagnostics (**shown to user before sending**). Separate paths: bug · wrong card data · request a card · general. States a response expectation.

### H10. What's New ⭐ (was missing)
Changelog shown once after each update; especially important when reward data or recommendation logic changes, so users understand why advice moved.

---

# System Surfaces (6)

### S1. Home-Screen Widget — small (best card) / medium (best card + reason + top alert). Sensible fallback when location unknown. Tap → B1.
### S2. Quick Settings Tile — tap → B2 scanner.
### S3. Notifications — geofence (*"You're at DMart — use Axis Ace"* · actions: Scan / Mute here) · cap warning · deadline (fee/milestone/expiry) · bill due · needs-review. All deep-link to the exact screen.
### S4. Universal States — every screen implements **loading** (skeleton, never blank) · **empty** (explains what appears here and how) · **error** (plain language + cause + retry; never a raw exception) · **offline** (persistent chip; network features visibly disabled, not silently broken).
### S5. Forced Upgrade — blocking, with store link, when below minimum supported version.
### S6. Maintenance / Degraded — *"Sync paused — recommendations still work offline."* Core function must remain usable.

---

# Cross-Cutting Requirements

### Data honesty
- **Every financial figure carries an estimated/confirmed badge.** No exceptions.
- Data-freshness date on all card reward details.
- Never display a number the app can't justify through "Why this card?".

### Accessibility
- Text scaling to 200% without layout breakage · WCAG AA contrast in both themes · screen-reader labels on all controls and card art · 48dp minimum touch targets · **never encode meaning in colour alone** (cap/utilization warnings need icon or text too).

### Performance
- Home renders **< 500ms** cold · scan → recommendation **< 1s** · all recommendation logic local, no network in the critical path.

### Destructive actions
- Confirmation + undo wherever feasible · cards **archived, never hard-deleted** when they have history · account deletion double-confirmed with typed input.

### Localization
- All strings externalized from day one (English at launch) · Indian number formatting (lakh/crore) · ₹ throughout.

### Offline-first
- Every screen declares its offline behaviour · the core loop (scan → recommend → log) works with zero connectivity.
