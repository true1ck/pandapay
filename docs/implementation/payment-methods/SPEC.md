# Payment methods — implementation spec (v1)

Goal: let a user say HOW a transaction was paid (cheque, NEFT, net banking, auto-debit, EMI, pay later, ...) and make the
"Paid with" picker smart (irrelevant options hidden), WITHOUT changing anything that works today.

## Hard constraints (do not break)

1. `transactions.instrument` is NOT changed: same six values, same DB enum, same API list, same `TxnInstrument`
   enum. Cheque = instrument `upi_bank` + `payment_method = 'cheque'`.
2. `transactions.payment_method` already exists (migration 20261115030000, CHECK allows null/'upi'). SMS v2 writes `'upi'`;
   that meaning is unchanged. We only WIDEN the allowed values.
3. Spend categories (15 frozen slugs) are NOT touched.
4. SMS code is owned by ANOTHER session. Do NOT edit: `api/src/sms*`, `api/src/sms_v2/**`, `app/lib/features/sms*/**`,
   `app/lib/data/sms_*`, `packages/pandapay_domain/lib/src/sms_v2/**`.
5. Reward / card-state logic keys off `instrument == credit_card` only. Do not edit `card_state_v2.js`, reward engine, `TxnRail`.
6. An entry with no payment_method (all existing rows) must render and edit exactly as today.
7. Editing an existing entry must never wipe or change its saved method/instrument unless the user changes it.
8. Old API ignores unknown body fields; so the app may send `paymentMethod` safely. Deploy order is DB -> API -> app.
9. Performance rules (docs/PERFORMANCE_RULEBOOK.md): no history scan or heavy work inside `build`; rules engine is a pure,
   cheap function. Run `flutter test test/performance_guards_test.dart` before finishing.
10. No commits, no pushes, no prod, no deleting files. Leave changes in the working tree.

## Contract

`app/test/fixtures/payment_methods_v1.json` is the single source of truth (methods, labels, groups, valid instruments).
The Dart catalogue and the JS catalogue must each have a test that loads this fixture and asserts equality.

## Smart rules (pure function; input -> visible options)

Input: entryKind, selected instrument, selected method, amount (nullable), category slug (nullable), user has credit/debit cards.
- Tier hidden (impossible): see `hardHiddenRules` in the fixture.
- Tier suggested: when category slug is one of rent, emi, insurance, education, government and instrument is `upi_bank`, put
  Cheque / NEFT / net banking first. Never hides anything for category reasons alone (cash on delivery etc. stay possible).
- Tier more: everything not `mainChip` lives behind a "More" chip that opens a bottom sheet grouped by `group`.
- The entry's CURRENT saved value is always included, even if a rule would hide it.
- Choosing a method sets the instrument to the first valid instrument for that method (cheque etc. -> `upi_bank`);
  selecting an instrument clears a method that is not valid for it.
- Cash / cheque / bank methods: hide the card picker and the rewards/limit panels (existing logic for non-card instruments).

## Work split (disjoint files)

- DEV-A  DB + API: new migration (widen CHECK with NOT VALID then VALIDATE), `api/src/payment_methods.js` (catalogue +
  validate), `POST /transactions` and `PATCH /transactions/:id` in `api/src/index.js` accept/validate `paymentMethod`, return it;
  API tests incl. fixture parity.
- DEV-B1 app persistence: local outbox/db column, `logTransaction`/`updateTransaction` take `paymentMethod`, outbox flush
  sends it, `Transaction` parses/returns it. Local DB migration must be additive and tested on an existing DB.
- DEV-B2 app UI: `app/lib/features/payments/` (catalogue, rules, picker widget), wire Quick Add + Edit transaction, show the method in
  transaction detail. Tests incl. fixture parity and rules table.
- MONITOR: read-only review of every diff against the risk register; runs the full suites and compares to baseline.

Baseline (before any change): API `node --test` = 2336 pass / 1 fail (pre-existing: "every committed override file applies to its
CardPipeline record without error") / 37 skipped / 4 todo. Flutter baseline recorded in the scratchpad.

## Status (verified 2026-11-13)

- Migrations: `20261122000000_widen_transaction_payment_method.sql` (drops the old single-column CHECK, adds the wide CHECK `NOT VALID`)
  and `20261122000100_validate_transaction_payment_method.sql` (validates in its own transaction, because the migration
  runner wraps each file in one transaction). Applied from scratch on Postgres 16; constraint validated; one CHECK on
  `payment_method`; the database rejects unknown values and accepts `upi` and `cheque`.
- API: 16 end-to-end checks pass against the real database (create/retry/GET/PATCH keep/clear/reject).
- App: verified on the Pixel 9a emulator against the local stack: Quick Add (UPI / bank -> Cheque, More -> NEFT), Edit
  (round trip Cash <-> UPI / bank keeps the saved method; saving as Cash clears it), offline save of a cheque syncs with
  its method intact, profile name edit and avatar preset change still work.
- Known follow-ups (not blocking): transaction list rows and the Spending report still group by instrument only (they show
  "UPI from bank", not "NEFT"); the SMS reader does not yet fill the method (SMS code is owned by another session).
- Local test notes: the local Docker Postgres needs `fsync=off` on this machine (use a compose override kept outside the repo).
