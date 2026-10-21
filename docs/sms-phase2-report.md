# SMS Intelligence — Phase 2 Report (Device/Server Routing)

**Date:** 2026-10-21
**Scope:** wiring the Phase 1 fact contract into the live device pipeline and a server route. Broadened relevance gate on listener paths only; safe-discard → typed facts route; typed fact upload to `POST /sms/facts`. No legacy transaction path behavior changed.

## Changed files

| File | Change |
|---|---|
| `api/src/import_resolvers.js` | Added `istDayOfMonth`, `syncStatementDayFromFact`, `syncDueDayFromFact` — fact-variant resolvers mirroring the legacy healing rule (device facts carry explicit printed dates, so IST day-of-month is always derived from the fact's own date; `visibility='user'` days are never overwritten). Exported. |
| `api/src/sms_facts_route.js` | NEW route module: `registerSmsFactsRoutes(app, {requireAuth, withUserClient, persistSubscriptionMandate})` implementing `POST /sms/facts`. Hex64 validation of `sourceKey` + `bodyHash`, non-empty facts ≤20, `validateFactSet` (invalid → 400 `{error:'invalid facts', details:[...]}`), `upsertSmsSourceFacts`, then specialists: statement/due-day sync for payloads with `statementDate`/`dueDate`; `mandate_lifecycle` facts → `syntheticMandateParse` → DI'd `persistSubscriptionMandate`. Response `{sourceId, factIds, replayed, statementDayUpdated, dueDayUpdated, mandatePersisted}`. Route never fabricates facts and never rejects the whole set because one fact was unused. |
| `api/src/index.js` | Wire-up only: `require` of the new route module + registration with `requireAuth`/`withUserClient`/`persistSubscriptionMandate` before `POST /transactions/from-sms`. |
| `api/test/sms_facts_route.test.js` | NEW 7 tests on a fake client (replay idempotency, statement/due-day IST pinning e.g. `2026-10-12T18:30:00.000Z` → day 13, user-day protection, mandate persistence, 400-abstain posture, bad-hash refusal). |
| `app/lib/features/sms_import/sms_text_hint.dart` | Extracted shared `_looksOtpOrSecurity` / `_looksPromotional` helpers (absolute vetoes for both gates); added `capturesFinancialSms` = strict `looksLikeTransactionSms` OR autopay/mandate family OR failed/declined attempt with amount + payment cue. Strict gate itself untouched. |
| `app/lib/features/sms_import/sms_listener_service.dart` | The 3 listener entry points (background handler, incremental inbox page, foreground delivery) now use `capturesFinancialSms`. Card discovery (`readInboxSms`) and the backup import screen keep the strict gate deliberately. |
| `app/lib/data/local_sms_parser.dart` | Autopay limit regex now accepts `(?:[:-]|\s+(?:of|is|for))` separators, so "maximum limit of INR 2,000.00" (corpus `autopay_mandate`) is captured; `hasCompletedMovement` negation fix — "No money was debited" is no longer a completed movement, keeping failure notices in the failed family instead of review. |
| `app/lib/data/local/sms_facts_outbox.dart` | NEW device outbox: local `sms_facts_outbox` table (namespace + sourceKey key, facts JSON only — never the raw body), replay-safe `INSERT OR IGNORE`, backoff `pending`/`failed`/`acknowledge`, and `buildSmsFactsForObservation` minting typed facts: balance obs → `balance_snapshot`; failed obs → `mandate_lifecycle cancelled` (cancel wording) or `pending_or_failed_attempt` (failed, with biller/last4/amount); autopay obs → `mandate_lifecycle registered` only with ceiling > 0 AND merchant extractable, else abstain. Facts are validated against the device contract mirror before enqueue; invalid perception facts are dropped, not uploaded. |
| `app/lib/data/local/sms_import_store.dart` | The `local_ignore` capture branch now also mints + enqueues facts in the same savepoint before `intake.acknowledge` — a safe-discard no longer throws information away. |
| `app/lib/data/user_cards_repository.dart` | `logSmsFacts(envelope)` → `POST /sms/facts`. 404 → return false (older API image; facts stay queued); 400 → return true (drop: the device pre-validates against the same contract, so a 400 is a contract mismatch, never retried); other failures throw for the sync loop's non-fatal handler. |
| `app/lib/app/providers.dart` | `_syncPendingMessages` drains the facts outbox after the intake batch loop (acknowledge/failed on result). Non-fatal catch: fact upload failures never block transaction sync. |
| `app/test/data/sms_facts_outbox_test.dart` | NEW 15 tests: gate behavior, mapper mint/abstain cases, outbox persistence + backoff, capture integration (facts enqueued at safe-discard time, no body text stored). |
| `app/test/data/sms_family_corpus_test.dart` | Four cases flipped toward `expected`: `autopay_failed`, `mandate_cancelled`, `declined_attempt` now captured as failed/`localIgnore` observations; `autopay_mandate` ceiling `2,000.00` parsed. Fixture `baseline` narratives (only) rewritten to the measured Phase 2 state. |
| `app/test/fixtures/sms_family_corpus.json` | `baseline.device`/`baseline.server` narrative updates for `balance_only`, `autopay_mandate`, `autopay_failed`, `mandate_cancelled`, `declined_attempt`. Bodies and `expected` untouched. |

## Measured end-state per corpus case

- `balance_only` — captured; typed `balance_snapshot` fact queued; intake `localIgnore` ack; fact uploads via the drain, not the transaction path.
- `autopay_mandate` — captured; ceiling now parsed; typed `mandate_lifecycle registered` (merchant NETFLIX, limit 2000) reaches the server and persists a subscription mandate.
- `autopay_failed` — captured (was excluded); typed `pending_or_failed_attempt` (NETFLIX) reaches the server.
- `declined_attempt` — captured (was excluded); typed attempt fact with amount + credit-card instrument.
- `mandate_cancelled` — captured now, but deliberately no typed fact yet: the message's `e-mandate` wording classifies as autopay and a cancellation carries no ceiling, so the mapper abstains (Phase 4 will mint cancellations).

## Evidence

- `api`: `npm test` → **540 tests / 539 pass / 0 fail / 1 skip** (baseline was 533 + the 7 new route tests; the 1 skip is the still-DB-required suite).
- Flutter: `sms_facts_outbox` (15) + `sms_family_corpus` (24) + `sms_fact_contract` (7) → **46 pass, 0 fail**. All other SMS suites (`sms_capture_pipeline`, `sms_backup_xml_parser`, `local_sms_parser`, `local_first_sms`, `sms_intake_repository`, `features/sms_import/*`) → **132 pass, 0 fail**.
- `flutter analyze`: zero issues in all touched files (remaining reports are pre-existing infos elsewhere; two unused-import warnings in the new test fixed via `dart fix`).
- `test/data/transaction_cache_test.dart` times out (5 × 30 s) — verified pre-existing by rerunning the same suite in a detached worktree at the pre-Phase-2 commit (`e756489`, +3 −5, identical hangs). Not a Phase 2 regression; unrelated to SMS.

## Compatibility gate

- Legacy 533 API tests unchanged and green; `POST /transactions/from-sms`, `/from-sms/batch`, checkpoints, receipts untouched.
- Strict gate preserved for card discovery and `sms_backup_import_screen` — user-initiated import paths unchanged.
- Device facts storage carries only hashes/sender/timestamps/typed facts, never raw bodies; OTP/promo vetoes are absolute for both gates.
- Phase 1 hazards respected: no raw bodies in envelopes (80-byte constraint irrelevant), facts numeric-only amounts (no `₹`), deterministic ordering shared via the contract module.

## Risks / next

- `mandate_cancelled` facts intentionally abstain — Phase 4 (mandate intelligence) adds cancellation minting.
- The outbox drain runs opportunistically inside `_syncPendingMessages`; if no transaction sync occurs for days, queued facts ship with the next cycle (backoff caps retries). Acceptable for this phase.
- One通胀 source facts route returns 400 for invalid sets — device drops silently; debugging relies on `console.error` server logs (`POST /sms/facts error`).
- Phase 3 (product projections: availability from balance facts, schedule/unpaid-spend from mandate + attempt facts, alert family work) per handoff.
