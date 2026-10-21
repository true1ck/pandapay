# Uncommitted changes review — 2026-10-21

Scope: everything in the working tree at `dcf5e32` (master) that is not committed.
Most of it is **another session's** "SMS intelligence" work (typed-facts contract,
AI/Gemini queue, needs-review enrichment) plus a few of my own uncommitted lines.
This document reviews it, lists what is *not* ready to commit, and answers the
MoneyBack+ card question with device evidence.

## 1. Inventory

| Area | Files | Owner |
|---|---|---|
| API — typed facts + AI queue | `api/src/sms_facts.js`, `api/src/sms_facts_route.js` (new), `api/src/ai_fact_evidence.js` (new), `api/src/ai_queue_route.js` (new), `api/src/ai_provider_quota_route.js` (new), `api/src/gemini_queue.js` (new), `api/src/gemini_worker.js` (new), `api/src/sms_learning.js` (new), `api/src/sms_observation_migration.js` (new) + 7 new test files | other session |
| API — parser | `api/src/due_date_parser.js`, `api/test/due_date_parser.test.js` | other session |
| API — my account fix | `api/src/index.js` (2 hunks, already committed in `a3c72f7`) | mine (committed) |
| App — facts outbox + review | `app/lib/data/local/sms_facts_outbox.dart` (new), `app/lib/data/local/sms_import_store.dart`, `app/lib/app/providers.dart`, `app/lib/data/needs_review_repository.dart`, `app/lib/features/activity/needs_review_screen.dart` | other session |
| App — parser | `app/lib/data/local_sms_parser.dart`, `app/lib/features/sms_import/sms_text_hint.dart`, `app/lib/features/sms_import/sms_listener_service.dart` | other session |
| App — card day sync | `app/lib/data/local/financial_store.dart`, `app/lib/features/insights/payments_due_screen.dart` | other session |
| Console / infra | `console/lib/**`, `console/lib/features/dashboard/sms_ai_operations_screen.dart` (new), `docker-compose.yml`, `api/example.env`, `api/package.json`, `app/pubspec.yaml`, 3 new migrations | other session |
| App — my UPI-phantom filter | `app/lib/app/providers.dart` (`isUpiPhantom`) | mine (uncommitted, blocked) |

## 2. Test baseline (this working tree)

| Suite | Result |
|---|---|
| `api`: `npm test` | **624 pass / 1 fail / 1 skip** — the single failure is a *test-harness* gap, see B1 |
| `app`: `flutter test` | **1150 pass / 0 fail** |
| `flutter analyze` (touched files) | clean |

## 3. Blockers

### B1 — `api/test/sms_facts_route.test.js` fails: "overriding a due date re-heals the bill cycle with the corrected value"

`assert.equal(client.learningFeedback.length, 1)` → got `0`.

Cause: `smsLearning.recordConfirmedCorrection` requires consent
(`api/src/sms_learning.js:41-47`): it queries
`SELECT contributions_opt_in FROM profiles WHERE id = $1` and returns early when the
value is not `true`. The test's `fakeClient` has **no branch for that SQL**, so it
throws `fakeClient: unhandled SQL …`; the route catches it
(`api/src/sms_facts_route.js:244-248`, "Learning is auxiliary") and the INSERT into
`sms_learning_feedback` never happens. **The product code is correct** — it fails
closed without consent and never lets a learning outage undo a user's correction.

Fix (test only, 2 lines):

```js
if (sql.includes('contributions_opt_in')) {
  return { rows: [{ contributions_opt_in: true }] };
}
```

### B2 — MoneyBack+ (••8708) due date is still wrong, and the uncommitted work does not close it

See §4 for the full investigation. Short version: the parser now reads the
AutoPay SMS correctly, but (a) captured messages are never re-parsed, (b) the
amount-bearing evidence lands in the *previous* bill cycle, and (c) two
day-sync gates require a `statement_date` that AutoPay messages never carry.

## 4. MoneyBack+ investigation (device evidence)

### What the device shows today

`MoneyBack+ Credit Card — Due 20 Nov — Bill · 20 Oct — ₹0 (Amount not seen in SMS)`

Server card metadata (`cached_responses:user_cards`):

```
MoneyBack+ Credit Card  last4 8708  statement_day 20  due_day null
Tata Neu Plus HDFC      last4 1366  statement_day 20  due_day null
Flipkart Axis Bank      last4 7105  statement_day 26  due_day 2
```

### Why it differs from Tata Neu

Both HDFC cards receive a bare **"Statement Generated: For HDFC Bank Credit Card XX8708"**
SMS with **no amount and no due date** — the app stores it as a *bill* observation
with `statement_date` = receive-anchor and `confidence 0.6`.

* **Tata Neu (1366)** additionally gets a family SMS (`YY-MYTNEU-S`) carrying
  amount ₹8,331 and due 2026-11-08, dated **one day after** the statement → both
  land in the same 7-day cycle → the family-merge (committed in `a3c72f7`) carries
  amount + due into the current cycle → **Due 08 Nov, ₹8,331 ✓**.
* **MoneyBack (8708)** gets its amount+due from **HDFC AutoPay alerts**, which
  arrived **13 days before** the statement SMS → they open a *different* cycle →
  the amount-less statement stays "current" → **₹0, due from the fallback**.

Real captured AutoPay messages on the device (7, all for card 8708):

```
2026-10-07  AutoPay Alert!  Your HDFC Bank Credit Card 8708 bill  Total Amt: Rs.10944
            will be deducted from your A/C 1797 on 09/OCT/2026
2026-09-05  AutoPay Reminder: Rs.1147 will be deducted from HDFC Bank A/c 1797 on 08/SEP/2026 for Credit Card 8708 bill
2026-08-05  AutoPay Reminder: Rs.15660 will be deducted from HDFC Bank A/c 1797 on 08/AUG/2026 for Credit Card 8708 bill
2026-07-06  AutoPay Reminder: Rs.4150 will be deducted from HDFC Bank A/c 1797 on 09/JUL/2026 for Credit Card 8708 bill
```

Under the **old** parser these were rejected and parked in Needs review as
`no_transaction_match` (visible in `local_needs_review`). The real due day is
therefore **8 or 9**, not 20 — confirmed independently by the debit confirmation
`UPDATE: INR 15,660.00 debited from HDFC Bank XX1797 on 08-AUG-26. Info: CC …8708 Autopay SI-TAD`.

### The uncommitted parser is correct

Probe of the working-tree `LocalSmsParser` against the real captured bodies:

| message | result |
|---|---|
| AutoPay Alert (Oct 7) | `bill`, card 8708, amountDue **₹10,944**, due **2026-10-09**, conf **0.95**, `due_date_detected` |
| AutoPay Reminder (Sep 5) | `bill`, card 8708, amountDue **₹1,147**, due **2026-09-08**, conf 0.85 |
| AutoPay Reminder (Aug 5) | `bill`, card 8708, amountDue **₹15,660**, due **2026-08-08**, conf 0.85 |
| Statement Generated (Oct 20) | `bill`, card 8708, no amount, stmt 2026-10-20, conf 0.6 (receive-anchor) |
| slice autopay (5799) | `bill`, **card_last4 null**, biller "slice UPI credit card", due 2026-09-05, conf 0.95 |
| `UPDATE: INR 15,660.00 debited …` | `unknown` / review, due 2026-08-08 (completed debit, no amount) |

All of them are now captured (`capturesFinancialSms` → true).

### Why the device still shows ₹0 — three gaps

**B2a — no re-parse path (the root blocker).**
`sms_captured_messages.processed = 1` short-circuits reprocessing
(`app/lib/data/local/sms_import_store.dart:58` → `intake.wasProcessed`), and
`LocalSmsParser.version` is still **6** (`app/lib/data/local_sms_parser.dart:97`)
despite the new AutoPay rules. The 7 already-captured AutoPay messages will
therefore **never** become bill evidence. A parser change only affects *new*
messages. Fix: bump the version to 7 **and** make the import path reprocess
messages whose stored observation `parser_version` is older (or add a one-shot
re-parse over `sms_captured_messages`).

**B2b — cycle ordering.** Even with re-parsed evidence, `_mergeCycles`
(`app/lib/data/card_bill_ledger.dart:350`) sorts by statement date: the Oct 20
statement (no amount) is "current", the Oct 7 AutoPay (amount + due) becomes
"previous". The current row stays ₹0 unless the card's `due_day` is learned
(that is B2a + B2c) or the ledger infers the cycle cadence.

**B2c — two day-sync gates require a `statement_date` that AutoPay SMS never has.**
`app/lib/data/local/financial_store.dart:869` (card patch) and `:952` (day sync)
both demand `statement_date != null`; `app/lib/data/local/sms_import_store.dart:124`
does the same. An AutoPay observation has an explicit **due date** but no
statement date, so the card's `due_day` can never be learned from it. The gate
should key on "explicit due date + confidence ≥ .85", not on `statement_date`.

### The fix path once (B2a/B2c) are addressed

1. Re-parse → bill observation for 8708 (amount ₹10,944, due 2026-10-09, conf .95).
2. `sms_facts_outbox` mints a `bill_obligation` fact with `last4: 8708`,
   `dueDate`, `amountDueInr` (`app/lib/data/local/sms_facts_outbox.dart:292-317`).
3. `POST /sms/facts` → `applyFactSpecialists` → `importResolvers.syncDueDayFromFact`
   (`api/src/import_resolvers.js:681`) sets `user_cards.due_day = 9`
   (`due_day_source = 'sms'`).
4. Device: `card.dueDay = 9` → `payments_due_screen` falls back to
   `nextOccurrenceOf(9, statementDate 20 Oct)` → **Due 09 Nov** instead of the
   invented 20 Nov.

Only step 1 (re-parse) and step 3's reachability are missing today.

### Related gap (same family)

The **slice** autopay SMS parses to a bill with `card_last4 = null` and
biller "slice UPI credit card" → it never attaches to the SLCBNK card (5799).
`card_bill_ledger._familyNamesCard` only knows how to match a family to a card
by display name, and the app-side store patch is hardcoded to one pair
(`sms_import_store.dart:130`: `sender.contains('TNEU') && cardName.contains('tata')`).
Slice would need the same family→card mapping.

## 5. Risk findings (non-blocking, should be tracked)

| # | Severity | Finding |
|---|---|---|
| R1 | med | `smsBackgroundFlushProvider` now runs the **full** flush (inbox scan + review retry + AI reconcile) on a 90-second timer (`app/lib/app/providers.dart` ~5386). Previously it ran on resume + startup. 90s content-provider polling is battery/bandwidth heavy; prefer a longer interval or run only the AI reconcile on that timer. |
| R2 | med | `reconcileAiNeedsReview` does a status call per review item (up to 20) on every cycle, forever. When the server has AI disabled (`AI_WORKER_TOKEN` empty → accept refused) the app keeps polling and never converges. Back off, or only reconcile items the app actually submitted. |
| R3 | med | Raw SMS bodies now leave the device for review items (`providers.dart` → `submitAiJob(body: message.body)`). The server redacts before storing and before calling Gemini (`api/src/gemini_queue.js:31-44`, `ensureSourceRow` stores only `body_hash`), and the consent copy was updated (`sms_consent_screen.dart`) — but the raw body transits the API process. Verify the "Anonymization audit" CI gate covers `ai_jobs.payload`. |
| R4 | med | `capturesFinancialSms` widens capture to mandate-family and failed-attempt SMS → more raw messages retained on device (2 644 already). Confirm the purge/consent story covers the widened set. |
| R5 | **med-high** | The new AutoPay due-date patterns in `api/src/due_date_parser.js` (`deducted|debited … on DATE`) also match **completed debit alerts** — e.g. `UPDATE: INR 15,660.00 debited from HDFC Bank XX1797 on 08-AUG-26` yields a due date. The app parser contains it (that message lands as `unknown`/review), but on the server the same pattern set feeds card-bill parsing, where a plain debit could be recorded as a bill due date. Require card/bill context in the pattern (e.g. only when the body also mentions `bill`/`card`). |
| R6 | low-med | `sms_facts_outbox` rows never expire. Against an older backend (no `/sms/facts`) every row is retried forever → unbounded growth. Add a TTL/cap. |
| R7 | low | Two sources of truth for family→card attachment: generic `_familyNamesCard` in `card_bill_ledger.dart` vs the hardcoded `TNEU`/`tata` check in `sms_import_store.dart:130`. |
| R8 | low | The override route re-runs specialists with `userCardId: null` (`api/src/sms_facts_route.js:249`), so a corrected due date for a card-resolved fact may lose its card binding on the re-run. |
| R9 | low | `fact_overrides` upsert keys on `(source_id, fact_index)`; the read path applies overrides before specialists — confirm a deleted fact is not resurrected by a late override. |
| R10 | info | 3 new migrations (`20261021210000_ai_jobs.sql`, `20261021220100_sms_learning_feedback.sql`, `20261021220000_ai_provider_capacity.sql`) are **not yet applied on prod** — the deploy runs `db-migrate` automatically, so they will land with the next deploy. Code that queries `ai_jobs` must not run before that. |
| R11 | info | The Gemini worker is dev-only (`docker-compose.yml`, `profiles: ["sms-ai"]`, opt-in token) ✓. `docker-compose.prod.yml` was not touched ✓. `GEMINI_API_KEY` stays server-side ✓. |
| R12 | info | `api/src/index.js` still carries another session's hunks (imports at line 17, `/transactions` at ~5076) next to my committed account-summaries fix. Any future commit of that file must be hunk-scoped (I used a filtered patch). |

## 6. Scenario matrix for the new AutoPay path

| Input | Capture | Parse | Expected outcome | Status |
|---|---|---|---|---|
| `AutoPay Alert! … Credit Card 8708 bill Total Amt: Rs.10944 … on 09/OCT/2026` | yes | bill, ₹10,944, due 2026-10-09, conf .95 | card 8708 gets `due_day = 9` via fact → device shows Due 09 Nov | **blocked by B2a/B2c** |
| `AutoPay Reminder: Rs.1147 will be deducted … on 08/SEP/2026 for Credit Card 8708 bill` | yes | bill, ₹1,147, due 2026-09-08, conf .85 | same | blocked by B2a/B2c |
| `UPDATE: INR 15,660.00 debited from … XX1797 on 08-AUG-26 … 8708 Autopay SI-TAD` | yes | `unknown`/review + due 2026-08-08 | must NOT become a bill | app OK; **server pattern risk (R5)** |
| `Your slice UPI credit card bill will be debited on 05-09-2026 via autopay from your savings account ending 5799` | yes | bill, due 2026-09-05, `card_last4 = null` | should attach to SLCBNK 5799 | **not attached (family gap)** |
| `Rs 500 was auto-debited from A/c XX1797 for NETFLIX on 20-10-2026` (completed) | yes | transaction (existing test asserts this) | stays a spend | ✓ |
| `Rs 500 will be debited tomorrow` (future debit, no bill marker) | yes | `futureDebit` → no spend | never becomes spend | ✓ |
| `No money was debited` failure notice | yes | not a movement | no spend | ✓ (new negation guard) |
| OTP / promo / security alert | no | — | never stored | ✓ (absolute vetoes) |
| Card statement `Statement Generated … XX8708` (no amount/due) | yes | bill, conf 0.6, stmt = receive-anchor | opens a cycle, amount unknown | ✓ (but drives B2b) |
| `New Bill Alert: Your AxisBankCC Bill 7263805712 of Rs.2147.00 is due on 02-Nov-2026` | yes | bill | Flipkart Axis: Due 02 Nov, ₹2,147, Paid ✓ | ✓ verified on device |

## 7. Recommended sequencing

1. **Fix B1** (test harness) → API suite green → unblocks CI.
2. **Decide the MoneyBack path** (B2a/B2b/B2c). Smallest version that ships:
   * bump `LocalSmsParser.version` to 7 and re-process captured messages whose
     observation `parser_version` is older (one-shot, idempotent);
   * change the two `statement_date != null` gates to "explicit due date + conf ≥ .85"
     for the **due day** only (keep the statement-date gate for the statement day);
   * then let the existing fact pipeline teach the server `due_day = 9`.
3. **R5** — constrain the server AutoPay due-date pattern to card/bill context.
4. **R1/R2** — soften the 90-second timer and the AI reconcile polling.
5. **R3** — confirm the anonymization audit covers `ai_jobs.payload` before the
   AI path is enabled in prod.

## 8. Commit-readiness verdict

| Change set | Ready? |
|---|---|
| `api/src/index.js` account-summaries fix | **Committed** (`a3c72f7`), deployed |
| `app/lib/data/card_bill_ledger.dart` + its test (family merge) | **Committed** (`a3c72f7`), deployed, verified on device |
| `app/lib/app/providers.dart` `isUpiPhantom` | Verified on device (7 → 6 accounts) but **uncommitted** — the file also carries another session's `sms_facts` wiring; commit hunk-scoped |
| API typed-facts + AI queue + console + migrations | **Not ready** — B1 must be fixed first; R3/R5/R10 should land with it |
| App parser + facts outbox + needs-review | **Not ready** — B2a/B2c are required for the headline behaviour (MoneyBack) to work at all; R1/R2/R6 before ship |

Nothing here blocks the deployed backend: the production image is `a3c72f7` and the
app on the phone shows 6 accounts, Tata Neu 08 Nov ₹8,331, Flipkart Axis 02 Nov ₹2,147.
