# SMS Intelligence — Phase 0 Baseline Report

**Date:** 2026-10-21
**Scope:** fixtures + baseline recording only (no product behavior change, no Gemini work)

## Deliverables

| File | Purpose |
|---|---|
| `app/test/fixtures/sms_family_corpus.json` | Single labeled corpus: 23 cases with `id/sender/body/family/expected/baseline`. Shared by device + server tests (same pattern as `local_sms_cases.json`). |
| `app/test/data/sms_family_corpus_test.dart` | Device baseline: gate sensitivity/industry vetoes + `LocalSmsParser` outcomes per case; store-level duplicate delivery and identity tests. 24 tests. |
| `api/test/sms_family_corpus.test.js` | Server baseline: `parseSmsAgainstPatterns([])`, `parseSubscriptionMandate({sender, body})`, `extractStatementDate`, `redactSmsShape`. 16 tests. |

## Baseline test results (full suites, after adding the corpus)

- `api` `npm test`: **521 pass / 0 fail / 1 skip** (505 pre-existing + 16 corpus). The skip is the DB-required test, unchanged.
- Flutter SMS suites (14 files): `local_sms_parser`, `local_first_sms`, `sms_capture_pipeline`, `data/local/sms_intake_repository`, `card_bill_ledger`, `card_bill_provider`, `needs_review_repository`, `sms_inbox_scanner`, `sms_capture_worker`, `sms_background_queue`, `sms_text_hint`, `sms_backup_xml_parser`, `sms_family_corpus` — **all pass** (661 + 24 etc.; 0 failures).
- Compatibility gate: pre-existing suite counts unchanged (505→521 = +16 new only). No product code was modified in Phase 0 (`git status`: only new test/corpus/report files added by this phase).

## Measured baseline behavior (per family)

### Device (gate → parser)

- **Gate excludes** (never reaches parser, by design today): failed/declined attempts (`failed`, `cancel(led)`, `credit_denied/limit_exceeded/due_to_insufficient`), OTP bodies, call-forwarding notice (no transaction keyword), pure cashback-offer body (promo words + `Apply now`).
- **Capture → localIgnore (server never learns):** balance-only observations (`local_sms_parser.dart` writes `balance_paise` to the observation table, then intake is terminal-acked as `local_ignore`), AutoPay mandate setup observations.
- **Capture → review (false-review screenshot cases):** HDFC "Transaction Check Alert" and Kotak Neo settlement payout land as generic unknown review items.
- **Correct classification today:** debit+balance (spend), salary credit (income), ATM withdrawal / reversal / refund / card-bill payment / cross-bank transfer (transfer), card statement + due bills (bill observations with distinct amounts/dates), named person debit (spend; profile-name match would make it self-transfer, 2-token rule holds for namesakes).
- **Delivery identity:** identical sender+body (any delivery gap, even seconds) maps to the same `sms_source_key`, so chase-delivery duplicates collapse to one observation/provisional transaction/intake row. Exact re-sends days apart collapse too — recorded as a known limitation in `import_source_key.js` (v4 arg intentionally unused); a versioned source-identity design must add a new key, never change the legacy hash.

### Server (conservative parser, probed directly)

- Correct: spend w/ balance snapshot; transfer kinds `card_bill`, `refund`, `reversal`, `cash_withdrawal`, `incoming_bank_transfer_candidate`; salary `income`; POI `payment_to_person` spend; mandate register ceil 2000; statement day extract (12-10-26 → 2026-10-12, explicit).
- Gaps (pre-declared, verified, awaiting later phases):
  1. **`hdfc_txn_check_alert` → server posts a spend 2000** with merchant "contact you twice to …" (false positive for a verification alert; device correctly refuses a local transaction but the same shape would be synchronized from a review screenshot path).
  2. Mandate extraction: merchant "NETFLIX with" (trailing preposition), cadence inferred 30d not explicit.
  3. Device-side merchants & limit: `to`-path merchant capture swallows the account clause (`"A/c XX1234 to Sujay Enterprises"`), server merchant is a derived "Transfer to X"; device limit extractor misses `"maximum limit of INR 2,000.00"` (only `"Max limit: …"` shapes).
  4. Balance-only and mandate observations are `local_ignore`-acknowledged before any server sync (data the server can use to enrich card/account state is thrown away).
  5. `ambiguous_suffix_two_banks` server text parses as a `payment_to_person` **spend** with party "another bank" — no automatic cross-bank pairing happens (good on pairing, weak on spend classification for self-bank clauses).

## Compatibility gates — status

| Gate | Status |
|---|---|
| Existing parser/intake/flow tests unchanged | ✅ (0 new failures) |
| No behavior change committed in Phase 0 | ✅ (tests + fixtures only) |
| Prod needs-review / review-path flow untouched | ✅ |
| Background capture path untouched | ✅ |

## Risks / notes

- The corpus deliberately asserts *today's* behavior; later phases flip assertions toward `expected` and must rewrite the `baseline` narrative per case, not the fixtures' message text (bodies double as realistic bank wording; e.g. mandate body avoided the word "debit" to respect the device gate's non-spend vocabulary).
- `LocalSmsParser.sensitive()` confirmed to veto OTP bodies before persistence — matches the "sensitive data" firewall expectation for later phases (Gemini prompts run after this veto).
- Windows env note: `rg` unavailable; use `Select-String`/Grep.

## Next

Proceed to Phase 1 per the handoff: define the typed-fact schema/migration surface (server multi-fact ingest contract) with candidate fixtures from this corpus as the contract test seed. Device-side known fixes queued for Phase 2+: terminal-ack for global observations, mandate-limit wording, `to`-path merchant capture.
