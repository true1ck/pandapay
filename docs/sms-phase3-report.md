# SMS Intelligence — Phase 3 Report (Product Projections)

**Date:** 2026-10-21
**Scope:** make the typed fact feed a real input for projections: bill obligations now reach `POST /sms/facts` with role-separated money, statement/due-day healing dedupes, and every recognized non-spend family is proven accepted by the server contract verbatim.

## Changed files

| File | Change |
|---|---|
| `app/lib/data/local/sms_facts_outbox.dart` | Bill branch in `buildSmsFactsForObservation`: a bill observation with a due date mints `bill_obligation` facts per role — `due_total` (amountDueInr) plus `due_minimum` (minimumDueInr). Roles stay separated so the total is never collapsed into one number; `billerName`, `statementDate`, `last4`/`accountLast4` + `credit_card` instrument ride along. Without a due date the bill abstains (needs review rather than a half-trusted fact). |
| `app/lib/data/local/sms_import_store.dart` | Bill captures now also enqueue minted facts (legacy observation sync unchanged — both feeds are INSERT-OR-IGNORE/idempotent). |
| `api/src/sms_facts_route.js` | Specialist loop deduplicates repeated `statementDate`/`dueDate` payloads inside one envelope: a bill with due_total + due_minimum heals each distinct date once. |
| `app/test/data/sms_facts_outbox_test.dart` | New corpus minter tests (card_statement 2 facts, bill_with_offer 1 fact, family set pins for balance/attempts/mandates); capture test now asserts bills ride BOTH feeds. |
| `app/test/fixtures/sms_family_corpus.json` | Baseline narratives updated for `card_statement`, `bill_with_offer`, `mandate_cancelled` (which does mint a cancelled fact — earlier note corrected). |
| `api/test/sms_facts_route.test.js` | New test: two-role bill post → 2 facts stored, exactly one statement-day and one due-day heal. |
| `api/test/sms_family_corpus.test.js` | New group: device-minted shapes for balance_only, card_statement, bill_with_offer, autopay_mandate, autopay_failed, mandate_cancelled, declined_attempt validate under the server contract verbatim. |

## Projection inventory (present and consuming facts)

- Home "as of" balances: `financial_store.dart:552` `BankAccountSummary.availableBalance` + `latestBalanceSmsAt`, rendered by Home ("as of"). Balance facts on the server keep the same `availableBalanceInr`/`asOfAt` shape.
- Card bill cycles: `card_bill_ledger.dart` consumes bill observations (statement/due days + totals) — now also fed by the typed route healers writing the same days.
- Commitments/mandates: registered and cancelled mandate facts persist through the legacy `persistSubscriptionMandate` writer (`recurring_series`), surfaced by `GET /recurring` and merged into Payments Due together with local `commitments_repository.dart`.
- No double count: mandate/attempt/balance/bill facts are written ONLY to fact/series/card tables, never to spend transactions; route has no transaction writer. Corpus gates (bill ≠ spend, mandate ceiling ≠ charge, repayment = transfer) stay green.

## Evidence

- `api` `npm test` → **542 / 541 pass / 0 fail / 1 skip** (adds 2 route/corpus tests).
- Device: `sms_facts_outbox` 18/18, corpus 24/24, contract 7/7, other SMS suites 132/132.
- Existing UI/domain reducers untouched; rewards/caps paths untouched.

## Compatibility gate

- Legacy observation sync for bills unchanged (both feeds row-coexist; facts route never converts facts into transactions).
- Phase 2 exit evidence unchanged and green.

## Risks / next

- `outstanding` reminder amounts (corpus `outstanding_reminder`) still review because the device parser lacks an outstanding field — deferred to review-kind work (Phase 4) and backfill/dry-run (Phase 7).
- Server `commitments` remain the recurring_series projection (no separate table); a dedicated server table would be additive only.
