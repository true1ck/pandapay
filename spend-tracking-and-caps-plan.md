# Plan — capture, cap-correctness, and the Insights/budgets build-out

> **STATUS: IMPLEMENTED.** Every workstream below has landed. See
> `IMPLEMENTATION_STATUS.md` for what each item became, the migrations
> added (0038–0040), the new modules, and the test counts. This file is kept
> as the original audit and rationale — the "why", which the code comments
> reference back to.

Audit date: 2026-08-25. Every claim below was verified against current code, not
against the docs (`GAP_ANALYSIS.md` is stale in several places). File/line
references are to the state of the tree at audit time.

---

## 0. What is already built and working (so we don't rebuild it)

Worth stating plainly, because three of the four things asked about are
*partly* built and the fix is narrower than "implement it":

| Thing | Status |
|---|---|
| **Cross-channel dedupe (SMS vs email vs statement)** | **Built.** `detectDuplicates()` (`api/src/index.js:2631`) runs on *every* insert through the one shared helper, matches same-amount / ±1 day / **different source** / still-active, scores 0.9 (merchant names agree) or 0.6 (one side has no merchant), writes `duplicate_candidates`. `GET /duplicate-candidates` + `POST /duplicate-candidates/:id/resolve` exist, and `app/lib/features/activity/duplicate_review_screen.dart` is a real screen on a real route. |
| **Re-import idempotency (same file imported twice)** | **Built.** `importSourceKey()` (`api/src/index.js:2608`) + migration `0036_import_idempotency`'s unique index on `transactions.source_key`. Re-sending a half-finished batch skips what already landed. |
| **Cap tracking per period** | **Built.** `cap_states` is period-bucketed via `periodBounds()`; `GET /user-cards` returns only the currently-active period's rows (`index.js:1852`); `_userCardSnapshots()` (`app/lib/app/providers.dart:1301`) turns that into real `capRemaining`. |
| **Cap blending in the recommender** | **Built, and carefully.** `RecommendationEngine._evaluate` (`packages/pandapay_domain/lib/src/engine/engine.dart:276-361`) handles all three `CapMeasure`s (`spendAmount`, `rewardValue`, `txnCount`) with pre-cap/post-cap splitting. |
| **Spend breakdown** | **Partly built.** `SpendingOverviewScreen` = current calendar month, by category + top-10 merchants. `InsightsOverview` adds this-month / last-month / 3-month earned, `byCategory` **and** `byCard`, and top-3 missed. |
| **Transaction query surface** | **Built.** `GET /transactions` already supports `from`, `to`, `cardId`, `categoryId`, `source`, `q` (`index.js:3157`) — weekly/yearly/per-card aggregation needs no new endpoint. |

So the work below is **six real bugs and one genuinely missing feature area**,
not a rewrite.

---

## Workstream 1 — Capture: get every transaction in, exactly once

### W1.1 — `user_cards` has no `last4`. This is *the* blocker. 🔴 P0

`POST /transactions/from-sms` **requires** `userCardId` (`index.js:2949`) and
says so honestly: the parser extracts amount/merchant/last4/date but *not*
which card. `sms_import_screen.dart:22` confirms it "does NOT attempt to
auto-resolve by last4 since `user_cards` carries no last4 column in this
schema." Verified — there is no such column in `0004_user_domain.sql`.

**Consequence:** every SMS and every email requires a human to pick a card.
There is no path today where a transaction is recorded without a tap. The
answer to "are we catching all transactions" is currently **no — we catch them
only if the user manually assigns each one.**

**Fix:**
1. Migration: `user_cards.last4 char(4)`, `user_cards.issuer_sender_hints text[]`.
2. Collect `last4` in Add-Card and Edit-Card (optional field, plainly labelled
   "last 4 digits — used to match your bank's SMS to this card"). Never the
   full PAN.
3. Server-side resolver: `resolveUserCardForImport(userId, {last4, sender})` →
   exact `last4` match wins; single-card-per-issuer fallback via sender; ambiguous
   or no match → `needs_review_items` (the table already exists and is already
   surfaced) instead of a 400.
4. Make `userCardId` **optional** on `/transactions/from-sms`, `/from-sms/batch`
   and `/inbound-emails/:id/create-transaction`, resolving when absent.

### W1.2 — Forwarded email never becomes a transaction on its own 🔴 P0

`POST /inbound-emails/webhook` (`index.js:5670`) parses the mail, records
`parsed_ok`, and stops. Creating the transaction is a *separate manual* call the
user must trigger per-email from the app.

**Fix:** when `parsed.ok` and W1.1's resolver returns a confident card, create
the transaction inside the webhook (source `'email'`, `raw_source_ref` set) —
which also means it flows through `detectDuplicates()` and gets deduped against
the SMS automatically, which is exactly what was asked for. Unresolved card →
`needs_review_items`.

### W1.3 — Email transactions are dated wrong 🟠 P1

`index.js:5851` passes `occurred: new Date()` — the *import* time, not the
transaction time — even though the parser has a `date` field
(`sms_parser.js:17` lists `date` as a known field). Two consequences: spend
lands in the wrong week/month, and dedupe's ±1-day window can miss the SMS
counterpart entirely if the email is read days later.

**Fix:** use `parsed.fields.date` when present, fall back to the email's
`received_at`, and only then to `now()`.

### W1.4 — IMAP is stored but never polled 🟠 P1

`imap_connections` holds an encrypted app password, `POST /imap-connections/:id/test`
does a real TLS LOGIN — and **nothing ever reads a mailbox**. `index.js:5571`
admits it: "a background IMAP poller that actually reads a mailbox (F7)".

**Decision needed (flagging, not deciding):** either build the poller (a cron
job walking `imap_connections` where `is_active`, fetching since `last_polled_at`,
feeding the same parse+insert path), or relabel the feature in-app so a user
isn't led to believe mail is being read. Storing a decrypted-able app password
for a feature that does nothing is the worst of the three options.

### W1.5 — SMS listening is foreground-only 🟠 P1

`sms_listener_service.dart:50` — `listenInBackground: false`, no background
handler registered. Transactions that arrive while the app is closed are only
picked up later by the backup-XML import path, if at all.

**Fix:** register `telephony`'s top-level background message handler; queue
matched messages locally and flush on next foreground. Note: this must be
squared against the Play-Store compliance work already done (`prod` flavor
dropped `READ_SMS`/`RECEIVE_SMS` in commit b62735b) — so this is a **dev/
sideload-flavor capability**, and the plan should say so rather than promise it
in the Play build.

### W1.6 — Imported transactions land uncategorized 🔴 P0

Nothing maps a parsed merchant name to a `category_id`. `/transactions/from-sms`
passes `categoryId: categoryId || null` and the app doesn't supply one. Two
knock-on effects, both severe:

- **Insights are empty/wrong.** Every SMS-imported rupee shows as
  "Uncategorized" in `SpendingOverviewScreen`.
- **Rewards are computed at base rate.** `applyTransactionState`'s rule match is
  `(category_id IS NULL OR category_id = $2)` with `$2 = null` — which can only
  ever match the base rule. A ₹5,000 Swiggy spend imported from SMS earns the
  card's 1% base rate, not its 5% dining rate, in *our own records*.

**Fix:** a merchant→category resolver, in this order — (1) exact `merchants.vpa`
hit, (2) normalized `merchants.display_name` match, (3) a shipped keyword/MCC
map (`swiggy|zomato → dining`, `irctc|makemytrip → travel`, …), (4) the user's
own past choices for that merchant string. Applied server-side at insert.
Category stays user-editable, and unresolved stays null rather than guessed.

### W1.7 — Dedupe improvements (the mechanism exists; sharpen it) 🟡 P2

- `transactions.dedupe_hash` is computed by a trigger and **indexed**
  (`0012_indexes.sql:16`) but **never read by anything.** Use it as the fast
  pre-filter in `detectDuplicates` instead of the current full range scan.
- **Auto-merge at 0.9.** Today a matched SMS+email pair both stay `active` and
  both count toward spend/caps/rewards until a human resolves the queue — which
  is precisely the double-count that was asked about. Recommend: score ≥ 0.9 →
  auto-ignore the later row (`status='ignored'`, reason `'duplicate'`, state
  reversed via the existing reverse path), record it in `duplicate_candidates`
  as `resolution='merged'`, and tell the user in the inbox — reversible, but
  correct by default. Score 0.6 keeps going to the review queue.
- Amount tolerance: exact-match only today. Add ±₹1 to survive rounding
  differences between an SMS ("Rs.1,234") and a statement line (1234.00).

---

## Workstream 2 — Ranking correctness: caps, limits, exclusions

This is the "₹3,000 monthly cap on a 10% card" question. The blending logic is
right; the inputs around it are not.

### W2.1 — Post-cap falls to ₹0, not to the card's base rate 🔴 P0

This is exactly the scenario described. `cap_rules.post_cap_rate` **defaults to
0** and `post_cap_unit` is nullable (`0003_card_catalogue.sql:85-86`); nothing
in the catalogue import populates either. The engine then does:

```dart
final postRate = capRule.postCapUnit?.effectiveRatePerRupee(...) ?? 0;
```

So once the ₹3,000 cap is consumed, the engine reports the card as earning
**₹0** on further spend. The real-world behaviour — and what was described —
is that it drops to the card's **standard base rate** (1%, 2%, whatever
`card_products.base_reward_rate` says).

**Fix:** in `_evaluate`, when a cap rule has no explicit post-cap rate, fall
back to the card's `baseRewardUnit`/`baseRewardRate` rather than 0. Explicit
`post_cap_rate = 0` (some cards genuinely earn nothing post-cap) must stay
distinguishable from "unspecified" — so this needs `post_cap_rate` to become
nullable, or a `post_cap_is_base boolean` flag. Nullable column is cleaner.

**Why it matters beyond the number:** at ₹0 the capped card sorts to the very
bottom, below cards that are genuinely worse than its base rate. The ranking is
wrong in both directions.

### W2.2 — Server and client disagree about which caps a transaction consumes 🔴 P0

- **Client** (`engine.dart:266`): `card.capRules.where((c) => c.rewardRuleId == rule.id)` — cap is tied to the *reward rule*.
- **Server** (`index.js:2718`): `WHERE card_product_id = $1 AND (category_id IS NULL OR category_id = $2)` — cap is tied to the *category*, and **`category_id IS NULL` matches every transaction**.

A grocery cap modelled the normal way (`reward_rule_id` = the grocery rule,
`category_id` = NULL) is therefore consumed by **every** spend on that card. A
₹50,000 rent payment silently burns the entire grocery cap. The recommender
then correctly reports "cap reached" — for a cap that was never really touched.

**Fix:** make the server's cap-consumption query mirror the engine:
match on `reward_rule_id = <the matched rule>` **OR** `category_id = <txn category>`,
and never on `category_id IS NULL` alone. Add a joint test fixture asserting the
two implementations consume identically for the same transaction — this class of
drift is the reason to have one.

### W2.3 — Recorded earnings ignore caps entirely 🔴 P0

`applyTransactionState` computes `rewardRate` from the matched rule's **nominal**
rate and writes `expected_value_inr = amount * rewardRate` (`index.js:2793`) —
no cap blending at all. So `GET /home-summary`, `GET /monthly-reports` and every
Insights "earned" figure **over-report** once a cap is exhausted. The
recommender is honest about the future; our record of the past is not.

**Fix:** compute `expected_value_inr` through the same blended arithmetic the
engine uses (post-cap portion at the post-cap/base rate), using the cap state
*as it stood before this transaction*. Same for `expected_points`.

### W2.4 — Four rule constraints exist in the model and are never enforced 🟠 P1

`RewardRule` carries `merchantPattern`, `rail`, `minTxn`, `maxTxn` — all present
in `reward_rules` in Postgres too (`0003_card_catalogue.sql:57-62`, plus
`effective_from`/`effective_to`/`conditions`). The engine's rule match is:

```dart
card.rewardRules.where((r) => r.categoryId == null || r.categoryId == context.categoryId)
```

**Category only.** `merchantPattern` is read once, purely to *display* it
(`engine.dart:430`). So:

- "10% **on Amazon** only" applies at every online merchant.
- "5% **on swipe** only" applies on UPI.
- "5%, **min txn ₹500**" applies to a ₹50 purchase.
- "5%, **max ₹5,000 per txn**" applies to a ₹80,000 purchase in full.
- A rule that **expired** last month still applies.

This is the "hotel booking / online / offline / other limits" case. All four
constraints are one predicate each.

**Fix:** extend the `where` to a real `_ruleApplies(rule, context, now)`
predicate covering merchant pattern, rail, min/max txn, and effective dates.
Where `maxTxn` is exceeded, blend (bonus rate up to `maxTxn`, base rate above)
rather than dropping the rule — that's how these actually work.

### W2.5 — No category-exclusion model at all 🟠 P1

Indian cards near-universally exclude rent, wallet loads, fuel, insurance,
government payments, EMI conversions and gift cards from earning. Only
`FeeWaiverRule.excludedCategoryIds` exists — nothing equivalent for reward
rules, and nothing on the card as a whole.

**Fix:** `card_products.excluded_category_ids uuid[]` and
`reward_rules.excluded_category_ids uuid[]`; engine returns a proper exclusion
(`"Rent doesn't earn on this card"`) rather than quietly paying a rate that
doesn't exist. This is also the single most common cause of "the app said I'd
earn X and I earned 0" complaints, so it's trust-critical.

### W2.6 — Surface it 🟡 P2

Once W2.1–W2.5 land, the information exists but nothing says it out loud:
- Home's verdict card should say "**cap exhausted — this is base rate now**"
  when `breakdown.capNote == 'Cap reached'`.
- Card list / card detail should badge a card whose headline cap is spent.
- The cap-threshold notification trigger built in the last session
  (`notification_triggers.dart`) already fires at 0.8 — extend it to fire again
  at 1.0 with "switch to <other card> for the rest of the month".

---

## Workstream 3 — Insights: budgets, trends, and everything-you-spend

This is the genuinely new feature area. Today: one month, one screen, category
+ merchant, and an explicit design note that it is "context, not a budgeting
tool" (`spending_overview_screen.dart:15`). What was asked for is the opposite —
so this is a deliberate product-direction change, not a bug fix.

### W3.1 — Spend Trends (weekly / monthly / yearly) 🟢 NEW

- Period switcher: **Week / Month / Quarter / Year / Custom**.
- Headline: total spend, txn count, average/day, **vs. previous period** (±%).
- Bar chart: last 12 weeks, or 12 months, or 5 years.
- Category and merchant breakdown per period (reuse the existing widgets).
- Day-of-week and time-of-day patterns.
- No new endpoint needed — `GET /transactions?from=&to=` covers it, and
  `GET /spend-by-category?months=` already exists for the category cut.

### W3.2 — Per-card spend report 🟢 NEW

`InsightsOverview.byCard` splits **earnings** by card already; there's no spend
equivalent, and `CardDetailScreen`'s six tabs (Rewards/Caps/Milestones/Fees/
Benefits/Statement) have no spend view.

- New **"Spend"** tab on Card Detail: this cycle vs last, category mix on this
  card, top merchants, effective earn rate (`earned ÷ spend` — the honest
  number, distinct from the headline rate), cap consumption timeline.
- A "compare my cards" view: spend, earned, effective rate, annual fee, net.
  This directly answers "is this card worth keeping" and feeds the existing
  Portfolio Audit screen.

### W3.3 — Budgets (weekly / monthly / yearly) 🟢 NEW

Currently **zero** budget code anywhere in app, api, db or domain (verified).

- New table `budgets`: `profile_id`, `scope` (`overall` | `category` | `card`),
  `scope_ref_id`, `period` (`weekly`|`monthly`|`quarterly`|`yearly`),
  `amount_inr`, `starts_on`, `rollover boolean`, `is_active`.
- New table `budget_periods` for historical performance (so "did I stay in
  budget in March" survives a budget being edited later).
- Screen: set a budget per category/card/overall; progress ring; projected
  end-of-period spend from current pace; over/under history.
- Notifications: reuse the `NotificationGate` built last session — new
  categories `category_budget_warning` (80%) and `category_budget_exceeded`.
  This is a natural fit for the existing gate, quiet hours and daily cap.
- Explicitly *not* a hard block — advisory only, matching the app's tone.

### W3.4 — Manual entries: cash, non-card spend, income, investments 🟢 NEW

Today `POST /transactions` **requires** `userCardId` (`index.js:2904`) — every
transaction must belong to a credit card, even though `transactions.user_card_id`
is already nullable in Postgres. So cash, debit, UPI-from-bank, income and
investments cannot be recorded at all.

- Relax `userCardId` to optional; add `transactions.instrument`
  (`credit_card` | `cash` | `debit` | `upi_bank` | `wallet` | `other`) and
  `entry_kind` (`spend` | `income` | `investment` | `transfer`).
- Card-less transactions **must not** touch cap/milestone/points state
  (`applyTransactionState` should early-return) — and must be excluded from
  reward figures while being included in spend/budget figures. Getting this
  boundary right is the main correctness risk in this item.
- QuickAdd gets an instrument selector; investments get their own light
  category set (SIP, stocks, gold, FD, insurance-premium).
- Insights then splits: **Spend / Income / Investments / Net**.

### W3.5 — Recurring & subscription detection 🟢 NEW

Nothing today (verified: no `recurring`/`subscription` code anywhere).

- Detector over history: same merchant, similar amount (±10%), ~monthly/annual
  cadence, ≥3 occurrences.
- New `recurring_series` table; surface as "Subscriptions" — monthly total,
  next expected charge date, "you're paying ₹X/yr for this", and a flag when a
  renewal is about to land on a card whose cap makes it a bad choice.
- Feeds a due-soon notification and the budget projection in W3.3.

### W3.6 — Make the monthly report real 🟠 P1

`monthly_reports.breakdown` is currently written as a literal note:
`'baseline/value-missed not computed this pass'` (`index.js:3795`). The columns
`baseline_single_card_inr`, `extra_earned_inr`, `value_missed_inr` exist and are
always 0.

**Fix:** compute them at month close from the transaction set — baseline = the
same spend on the user's single best card, extra = actual − baseline, missed =
optimal − actual. Store the category/card breakdown in `breakdown` jsonb so the
report opens instantly, which is what the table was designed for.

### W3.7 — Report export 🟡 P2

`GET /export` exists (full-account JSON). Add a per-period **CSV/PDF spend
report** — month, per-card, per-category — since this is the top "can I send
this to my CA" ask for a spend tracker in India.

---

## Workstream 4 — Extra data we need to capture

Consolidated list of what has to be collected or added that isn't today:

**From the user (one-time, low friction):**
1. Card **last 4 digits** — unblocks all automatic capture (W1.1).
2. Card **credit limit** — column exists, is often empty; needed for real
   utilization insights.
3. **Statement day / due day** — columns exist; needed for cycle-accurate caps
   and budgets aligned to the billing cycle rather than the calendar month.
4. **Budget amounts** (W3.3).
5. **Opening balances** for non-card instruments, if W3.4's cash tracking is
   to reconcile.

**From parsing (already in the message, currently discarded):**
6. **`last4`** — the parser extracts it and it is thrown away.
7. **Transaction date from email** — parsed but overwritten with `now()` (W1.3).
8. **Available-balance / available-limit** lines — most Indian bank SMS carry
   them; would give real-time utilization for free.
9. **Transaction type** (debit/credit/refund/reversal) — refunds are currently
   indistinguishable from spend, which corrupts both budgets and cap accrual.
10. **Rail** (`swipe`/`online`/`upi`/`atm`/`emi`) — the column exists and is
    almost always `'unknown'`; W2.4's rail-specific rules need it.

**In the catalogue (admin/scraper side):**
11. **`post_cap_rate` / `post_cap_unit`** on every cap rule (W2.1).
12. **`merchant_pattern`, `rail`, `min_txn_inr`, `max_txn_inr`,
    `effective_from`/`effective_to`** — columns exist, largely unpopulated (W2.4).
13. **Excluded categories** per card and per rule (W2.5).
14. **MCC → category** map, shipped as reference data (W1.6).

**New schema:**
15. `user_cards.last4`, `user_cards.issuer_sender_hints`
16. `transactions.instrument`, `transactions.entry_kind`
17. `budgets`, `budget_periods`
18. `recurring_series`
19. `card_products.excluded_category_ids`, `reward_rules.excluded_category_ids`

---

## Workstream 5 — Further improvements worth considering

Not asked for, offered as options — each is small relative to the above and
each raises the app's ceiling:

1. **"Where should I put this ₹X?"** — an inverse recommender: given a planned
   large purchase, show which card, whether to split it, and what it does to
   caps/milestones/utilization. All the machinery (`SplitOptimizer`) already
   exists and is only wired into a calculator screen.
2. **Cycle-aligned everything.** Budgets and spend views default to the calendar
   month while caps often run on the statement cycle. Offering "my billing
   cycle" as a period across all three would remove a real source of confusion.
3. **Year-in-review** — annual earned/missed/best-card/biggest-category. Cheap
   once W3.1 lands, and a strong retention moment.
4. **Refund and reversal handling** — see data item #9. Today a refund is
   recorded as more spend.
5. **Foreign-currency transactions** — `ForexRule` exists for *recommendation*,
   but there's no `original_currency`/`fx_rate` on `transactions`, so a foreign
   spend can't be reported as such.
6. **Shared/family view** — split a household's spend across two users' cards.
   Larger; flagging only.
7. **Goal-linked milestones** — "spend ₹1.5L by March for the free night" already
   exists as milestone state; giving it a countdown widget makes it actionable.

---

## Suggested sequencing

| Phase | Contents | Why this order |
|---|---|---|
| **1 — Trust the numbers** | W2.1, W2.2, W2.3, W2.4, W2.5 | Everything downstream (insights, budgets, notifications) reads these figures. Fixing capture first would just import more data into a miscounting engine. Pure logic + tests, no UI. |
| **2 — Capture everything** | W1.1, W1.6, W1.2, W1.3, W1.7 | `last4` first, since W1.2 and W1.6 both depend on knowing which card. Ends with dedupe auto-merge, once there's enough real cross-channel volume to exercise it. |
| **3 — Insights & budgets** | W3.1, W3.2, W3.6, W3.3 | Trends and per-card first (read-only over data that is now correct), then budgets on top. |
| **4 — Breadth** | W3.4, W3.5, W3.7, W1.4, W1.5 | Manual/non-card entries and subscriptions widen scope; the IMAP and background-SMS decisions can wait behind them. |

---

## Verification

- **Phase 1** is almost entirely testable in `packages/pandapay_domain` (pure,
  no IO — the existing `urgency_test.dart` style) plus API integration tests.
  The one test that must exist and doesn't: a **shared fixture asserting the
  Dart engine and the SQL in `applyTransactionState` compute the same
  cap consumption and the same expected value** for the same transaction. W2.2
  and W2.3 are both instances of those two drifting apart.
- **Phase 2** needs real bank SMS/email samples per issuer; the
  `parser_failures` telemetry table already exists to catch what we miss.
- **Phase 3/4** — widget tests per screen, plus a golden test per new chart
  (Alchemist is already the project's golden framework).
- On-device pass via the `android-emulator` skill at the end of each phase.

## Open decisions (need a call, not a guess)

1. **IMAP poller — build it, or remove the feature?** (W1.4) Storing a
   decrypted-able app password for a feature that does nothing is the worst
   available state.
2. **Background SMS** (W1.5) conflicts with the Play-Store compliance work
   already done. Dev-flavor only, or re-apply for the permission?
3. **Auto-merge duplicates at 0.9** (W1.7) — correct by default and reversible,
   but it does mean the app silently discards a row. Confirm the tone is right.
4. **Does the app become a general spend tracker** (W3.4 — cash, income,
   investments)? That is a real widening of scope from "credit-card rewards
   optimizer", with implications for onboarding, positioning and Play Store
   category. Worth being deliberate about rather than sliding into.
