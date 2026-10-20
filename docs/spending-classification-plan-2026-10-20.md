# Spending classification — deep dive, scenario matrix, and fix plan (2026-10-20)

Status: **implementation started**. The first ingestion/classification slice is implemented; historical reconciliation and relationship pairing remain planned follow-up work.
Companion UI mockups: `docs/design/spending-activity-redesign-2026-10-20.html`.

---

## 1. The reported bug, replayed against the code

User scenario: buy an ₹80,000 laptop on a credit card → spending shows ₹80,000
(correct). Pay the card bill (₹80,000 from Canara A/c → HDFC card 9080) →
spending now shows ₹1,60,000 (wrong) and the bill payment row sits in the list
with the same red clay treatment as a purchase.

Traced through both parsers:

### RC1 — A self transfer naming the destination bank becomes *spend* (the exact scenario)
`api/src/sms_parser.js:155-200` — `parseBuiltInAccountTransfer` matches
`"from A/c XX2626 to HDFC Bank …"`, extracts `transferParty: "HDFC Bank"`,
then keys the verdict on wording alone (`ownTransfer = isExplicitOwnAccountTransfer(body)`):
the message doesn't say "self transfer", so
`entryKind: ownTransfer ? 'transfer' : 'spend'` (line 197) → **spend**,
merchant `Transfer to HDFC Bank`, `transferKind: 'payment_to_person'`.

On-device parity has the same hole: `app/lib/data/local_sms_parser.dart:368-375`
— `_ownAccountTransfer` (line 179-181) only matches `"self transfer"`,
`"own account"`, `"between my accounts"`, `"from your…to your…account"`.
Real Indian SMs say *"Rs 80,000 transferred from A/c XX2626 to HDFC Bank
A/c XX9080"* — no "your" → classified `spend` with merchant `Bank transfer`.

**Note the give-away:** the host parser's own output already names it —
`merchant: 'Transfer to …'` on a row with `entryKind: 'spend'`. The built-in
debit fallback (`parseBuiltInAccountDebit`, line 336) bails to review as
`unverified_account_transfer` for the same shape, so the two built-ins disagree.

### RC2 — Credit-card bill payment phrasings that don't contain "credit card"
`api/src/sms_parser.js:414-418` and `app/lib/data/local_sms_parser.dart:676-678`
all require the literal words `credit card` near `towards / paid / debited`.
Missed real shapes:
- `"Debited ₹80,000 from Canara A/c XX2626 towards **card payment** TINPXXXX"` (no "credit")
- UPI bill pay through CRED/PhonePe: `"₹80,000 transferred to VPA happycreds@axisbank (UPI Ref …)"` — plain UPI purchase shape → spend
- `"Card Bill Pay of ₹80,000 successful"` (shuffle/hdfc app alerts)
- Narration-style: `"IMPS/HDFC TLP CC PMT Hyd UTR …"`, `"MYMANTL HBCC PMT"`
- Wallet-funded payment, autopay e-mandate hits phrased around the VPA.

### RC3 — Wallet top-ups (money added to *own* Paytm/PhonePe/Amazon Pay) count as spend
The screenshot's own list shows it: `Bank transfer … Wallet Load · Other −₹93.82`
as a spend-tinted tile. `api/src/merchant_category.js:12` maps the payee to the
category `Wallet Load`, but no path flips `entry_kind` to `transfer` — loading
your own wallet and paying merchants from it later therefore double-counts.

### RC4 — The receiving side of a self transfer becomes income
`api/src/sms_parser.js:238-241` — the HDFC credit alert
(`"credited to your A/c XY9080 from CANARA BANK"`) contains only **one**
account reference, so the `accountReferences.length >= 2` tripwire does not
fire → `entryKind: 'income'`. Money in is inflated in the same way money out
is (Activity currently shows `+₹29.17L in / −₹23.92L out`, both inflated).
When the shape *does* carry two account refs it goes to review as
`unverified_incoming_transfer` — again the built-ins disagree depending on
whichever half of the pair the user happened to capture.

### RC5 — No own-account evidence at parse time
Serverside, the user's own bank accounts already exist — Home's "Your bank
accounts" (`app/lib/app/providers.dart:2846` + `GET bank-account summaries`,
`issuer + accountLast4 + availableBalance`), derived from SMS observations.
Neither parser is given that registry (only `cards` are passed in), so
"A/c XX9080" in a transfer narration cannot be resolved as *one of mine*.
This is the missing signal behind RC1/RC4.

### RC6 — Both halves of one movement import as two rows
Funding-bank debit SMS + issuer credit SMS for the same ₹80,000 → two rows.
After RC1-RC3 fixes this becomes two `transfer` rows (never spends), so it
affects only transfer *counting*, but it should be paired/merged for a clean list.

### RC7 — The display-layer is correct; the defaults amplify the noise
`app/lib/features/activity/activity_screen.dart:435-444` — summary counts
`income` vs `spend+investment` with `status=='active'`; transfers are already
excluded from Money out, and `entry_kind='spend'` filters are already applied
across reports (`api/src/spend_reports.js`, `providers.dart:3976-4028`,
`insights`, `home_screen.dart:3104`). **The one legal accounting bug is all in
ingestion.** But the date filter defaults to `allTime`
(`activity_screen.dart:491`), so Activity shows lifetime "Money out −₹23.92L"
across 1319 transactions — every historical misclassification (and there are
hundreds) is visible at once, with no year context.

### Existing controls that the fix should reuse (do not reinvent)
- `TxnEntryKind` spend/income/investment/transfer — migration 0040, in sync at
  `app/lib/data/user_cards_repository.dart:260-274`; PATCH
  `/transactions` already accepts `entryKind` and reverses card state correctly
  (`api/src/index.js:6001-6066`).
- `metadata.transferKind` already flows into the ingest path
  (`api/src/index.js:3667-3685`) — no schema change needed to stamp movements.
- the needs-review queue (`needs_review_screen.dart`) + duplicate review —
  right homes for the historical cleanup.
- quick-add already supports a Transfer kind (`quick_add_screen.dart:1592`);
  edit screen allows spend→transfer repair (`edit_transaction_screen.dart`).

---

## 2. Full scenario matrix

Legend of the **target** verdict: `SPEND` (leaving the wallet for something
consumed), `TRANSFER` (moving money between pockets the user owns — bank,
card ledger, wallet, cash), `INCOME`, `INVESTMENT`, `—` (not a transaction).

| # | Scenario (real SMS shapes) | Today | Target | Where it breaks |
|---|---|---|---|---|
| **Setting a credit-card liability** |
| 1 | Buy laptop ₹80,000 on credit card ending 9080 | spend | `SPEND` | correct |
| 2 | Pay that bill from Canara A/c via app ("debited A/c 2626 towards HDFC/card PMT") | spend | `TRANSFER` badge *Bill payment* | RC1/RC2 |
| 3 | Pay bill via GPay/PhonePe/CRED (UPI P2A to VPA) | spend | `TRANSFER` | RC2 |
| 4 | Pay bill via netbanking / statement narration ("CC PMT", "TLP") | spend | `TRANSFER` | RC2 |
| 5 | Autopay e-mandate auto-debits ₹3,500 min due | spend | `TRANSFER` | RC2 |
| 6 | Third party (spouse) pays my card: "payment received towards your credit card" | transfer | `TRANSFER` | correct |
| 7 | Issue-level "payment received on card ending 9080" half-pair | varies | pair/merge with #2 | RC6 |
| 8 | Statement generated / total & min due reminders | none | `—` | correct |
| 9 | Reward redemption → statement credit | income | `INCOME` | ok |
| ** Money between the user's own pockets ** |
| 10 | Canara → HDFC own transfer ("transferred from A/c XX2626 to HDFC Bank A/c XX9080") | **spend** | `TRANSFER` badge *Self transfer* | RC1 |
| 11 | Receiving half: "credited to A/c XY9080 from Canara" | **income** | `TRANSFER` (paired) | RC4 |
| 12 | Intra-bank transfer (UB own a/c to own a/c) wording w/o "self" | spend | `TRANSFER` | RC1 |
| 13 | ATM cash withdrawal | transfer | `TRANSFER` badge *Cash* | correct |
| 14 | Cash deposit to own a/c | income | `TRANSFER` (or income when a pay-in) | minor |
| 15 | Add money to Paytm/PhonePe/Amazon Pay wallet | **spend** | `TRANSFER` badge *Top-up* | RC3 |
| 16 | Paytm/PhonePe wallet pays a merchant | spend | `SPEND`, Wallet instrument | ok |
| 17 | FD/RD opening / renew | review | `TRANSFER` badge *Investment-like* (later: own kind) | gap |
| 18 | FD maturity with interest (principal + ₹interest) | income | split: principal `TRANSFER`, interest `INCOME` | later |
| ** Real spending under a wrapper ** |
| 19 | Loan disbursal credit | income | `INCOME` (flag "funding, not earnings") | ok |
| 20 | Personal loan EMI | spend | `SPEND` (Feeding a plan, not a store) | ok |
| 21 | Insurance premium debit mandate (LIC, policy) | spend | `SPEND` (Insurance) | ok |
| 22 | Biller autopay (electricity, mobile, OTT) | spend | `SPEND` | ok |
| 23 | Rent to person / NoBroker rentpay | spend | `SPEND` | ok |
| 24 | P2P to a person (loan lent, gift, share of bill) | spend | `SPEND` by default, 1-tap reclass to `TRANSFER` | UX |
| ** Secured from double counting ** |
| 25 | Pending SMS then settled SMS (same txn) | deduped | deduped | ok (transaction_dedup) |
| 26 | Original charge reversed (refund of ₹2,000) | income | `INCOME` badge *Refund*; optionally net against spend in period | later |
| 27 | Failed/declined/collect-request/OTP/balance/limit/promo/mandate-setup | none | `—` | ok |
| 28 | Convert purchase to EMI | income | `—` + amortization note (the ₹80,000 already counted) | usually near-miss |

Rule this matrix encodes: **spending decreases what you can consume; transfers
re-shape what you own.** If money ends a movement in a pocket the user still
owns (other bank a/c, own card ledger, own wallet, cash), it is not spending.

---

## 3. Target behaviour (one sentence each)

1. Every ingest path stamps a `movement subtype`, derived free of charge from
   fields we already have: `card_bill`, `self_transfer`, `wallet_load`, `cash`,
   (later `fd`, `loan`) — carried today by `metadata.transferKind`.
2. Bill payments, self transfers, wallet top-ups, cash and investments:
   never counted in any spending figure — with **visible badges in Activity**
   so the exclusion is legible, not mysterious.
3. Spending figures everywhere are computed from `entry_kind='spend'` only
   (already true at every call site — keep + pin with tests).
4. Default Activity window = **current year** (not lifetime).
5. Wrongly-imported history is repaired by the user with a **batch confirm**
   screen — never silently rewritten (per the existing audit rule).

---

## 4. Implementation plan (ordered, smallest diff first)

### Phase 1 — Classification (root causes RC1-RC4)

1. **Extend `parseBuiltInCardBillPayment` / its Dart twin** with the missing
   shapes (§1 RC2): `"card payment"`, `"card bill"`, `"CC PMT"/"CC bill"`,
   known payer VPAs (CRED-ish patterns configurable list), issuer+card-last4
   in narration. Emit `transferKind: 'card_bill'`, merchant
   `Credit card bill payment` (unchanged).
2. **Own-account registry at parse time.**
   - Local: pass the persisted `BankAccountSummary` list into
     `LocalSmsParser.parse()` the same way `cards` already flows
     (`local_sms_parser.dart:392`), and hold it in the store/worker path.
   - Server: `importParsedMessage` (`index.js:3658`) already owns a client —
     fetch/fetch-and-cache `GET user bank accounts` keyed by profile and match
     destination `issuer+last4` (parsers already capture `destinationAccountLast4`,
     `destination_account_last4` insert column exists at `index.js:3485`).
   When destination matches an own account → `entryKind:'transfer'`,
   `transferKind:'account_to_account'`, merchant `Transfer to own <Issuer> A/c`.
   When a credit alert's **source** matches an own account → pair as the same
   transfer instead of `income`.
3. **Wallet top-up:** in `parseBuiltInUpiDebit`/`parseBuiltInAccountDebit`
   (and Dart twins) — payee matches wallet-load patterns
   (`paytmwallet|phonepe-wallet|amazonpay|mobikwik` `+ "add money|top up|wallet load"`)
   → `entryKind:'transfer'`, `transferKind:'wallet_load'`.
4. **Leak fix left in place intentionally:** `parseBuiltInAccountTransfer`
   keeps `payment_to_person` → `spend` for named people (P2P rent is spending);
   it only loses "the party is flushed with an account suffix" — see Decisions.
5. **Tests:** port the scenario matrix (§2) as table-driven unit tests on both
   parsers (`api/test/…`, existing Dart parser test patterns), one row per
   scenario. This is the regression harness the existing audit doc calls for.

### Phase 2 — Activity UI (mark it, count it, default it)

1. **Movement badge/colour map** (single helper next to `TxnEntryKind`):
   | Movement | Badge | Icon | Amount colour |
   |---|---|---|---|
   | Spending | — | arrow-up | clay `#E8623C` |
   | Money in | — | arrow-down | jade `#12805C` |
   | Transfer · card bill | `Bill payment` (indigo `#5A6FD6`) | swap | neutral `ink900` |
   | Transfer · self transfer | `Self transfer` (cyan `#2B9DB7`) | swap | neutral |
   | Transfer · wallet load | `Top-up` (amber `#E99A2F`) | swap | neutral |
   | Investment | `Investment` (violet `#8064C7`) | trending-up | neutral |
   (Bamboo rule: chips are tinted pills with dark ink on paper — lime never as
   text on paper. Mockup file mirrors these exactly.)
2. **Summary card** relabel: `Money out` → **Spending**, and a third footnote
   row: `Excluded: ₹1.84L · 14 bill payments · 9 self transfers · 3 top-ups`
   in `onSlateSubtle` (see mockup frame A). The count stays spend+investment.
3. **Type chips:** add `Bill payments` / `Self transfers` chips next to the
   existing All/Spending/Money in/Transfers/Investments (filter + colors);
   keeps the user's request "marked with a different color".
4. **Default date preset → this year:** `ActivityFilter.datePreset` default
   `_ActivityDatePreset.thisYear`; the provider then takes the server-filtered
   path (`hasServerFilter` already triggers on `from != null`) — nicer payload
   too. Keep `All time` available in the date sheet. Internal links that pass
   explicit filters unchanged.
5. **Quick-add & edit:** expose the four kinds already supported
   (spend/income/transfer/investment) plus *why this matters* microcopy
   ("Transfers don't count as spending").

### Phase 3 — Repair history (user-confirmed, never bulk)

1. New screen (needs-review pattern): **"Looks like transfers"** — server
   query `entry_kind='spend' AND (merchant_name ILIKE 'Transfer to %' OR
   merchant_name ILIKE 'Bank transfer' OR merchant_name =
   'Credit card bill payment')` (plus RC3 wallet patterns), rendered as a
   checkbox list with a *current → suggested* kind per row; confirm POSTs
   `PATCH /transactions` per row (server already reverses card state,
   `index.js:6001-6066`).
2. Safety rails: list caps at 100 rows with a "load more"; rows that moved card
   show the state-impact note; amount, issuer and date are displayed for
   sanity — this honours the existing rule *"no silent bulk amount/merchant
   matching is safe"*.
3. After Phase 1 ships, new mail arrives correct; this screen shrinks and is
   meant to be retired.

### Phase 4 — Polish

1. Spend trends / insights screens: one-line caption
   *"Transfers, bill payments and investments are not counted"* (the copy trick
   already exists in `insights_hub_screen.dart:575`).
2. Pair funding-debit + issuer-credit halves of the same bill payment into one
   list row (RC6) — display-only, keep both rows under the hood.
3. Refund-netting inside a period (matrix #26) — a separate future proposal,
   do not bundle.

### Decisions to confirm before Phase 1
- **D1:** Is an own-account match by `issuer+last4` enough without user
  confirmation? (Recommend: yes for `self_transfer` marking — needs the Home
  card's "this account is mine" only as a fallback.)
- **D2:** Do we *hide* transfers from the default list view? (Recommend no:
  show with neutral tint + badges; the type chips already give one tap to a
  spend-only view.)
- **D3:** P2P-to-person stays spend by default, with 1-tap reclass (matrix #24).

---

## 5. Why this passes the user's scenarios after the fix

| Step | Entry import | Spending after |
|---|---|---|
| Buy laptop ₹80,000 on card 9080 | `spend` (credit_card) | ₹80,000 |
| Pay bill ₹80,000 from Canara | `transfer` · *Bill payment* badge | **₹80,000 (unchanged)** |
| Self transfer Canara → HDFC | `transfer` · *Self transfer* badge | **₹80,000** |
| Wallet top-up ₹93.82 | `transfer` · *Top-up* badge | **₹80,000** |
| PhonePe wallet later pays Swadisht | `spend` (wallet) | ₹80,000.15 |
| History repair screen | bad rows → transfer | ₹80,000 |

Trust property: the summary's Spending number only moves when money actually
left for something consumed.
