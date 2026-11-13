# WP-C10 — Import and export work offline

Findings: Q-05, W-13, R-08, K7. Decision D7 applied.

## What changed
1. **Statement import continuation is ON by default** (`Env.statementImportContinuationEnabled`, default `true`; pass `--dart-define=PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED=false` to turn it off). The reviewed batches are encrypted into the outbox *before* the first upload (already how `prepareAndRun` works). A transport failure (no network, timeout, 502-504) now ends on "Saved on this phone — will upload when you're back online" instead of an error. A definite server refusal (4xx/500) with nothing confirmed discards the saved plan and unlocks the preview (same as the old non-continuation behaviour), under a fresh session id.
2. **Auto-resume**: `statementImportAutoResumeProvider` (read from `outboxFlushProvider`, one line in `providers.dart`) resumes saved imports on reconnect, app resume, an outbox flush request, and shortly after startup. It does nothing unless the DB has pending encrypted batches. No timers. `StatementImportContinuation.autoResume()` drains each non-parked session; a failure stops the pass.
3. **Idempotency / parking**: importKey is the existing deterministic sha256 per batch; the server replays 200. HTTP 409 `statement_import_key_reused` parks that session (in memory, reason shown on the pending card, never retried automatically, rows kept). `confirmPreparedStatementImport` now keeps the response body in its `ApiException` so the error code is visible. `QueueRegistry` already counted `statement_import` batches (verified, no change).
4. **Review duplicate check** reads the local `FinancialStore` (`ResponseCache.readTransactions`), not `fetchTransactions()`. Server stays the final dedupe.
5. **Data export** is built on the phone (`lib/data/local_export.dart`) from stored rows incl. unsynced ones; same columns/order/sections as `GET /export` (`api/src/index.js`). PDF renders from the local CSV. The screen says so.
6. **Data & Storage record count** uses `FinancialStore.transactionCount` (one COUNT).
7. **Import hub / Data transfer "recent imports"**: last list cached in `ResponseCache` (`statement_imports`, `sms_import_batches`), shown offline with "Updated ..." time; section hidden when offline with no cache.
8. **Find Cards**: the on-phone SMS result is shown immediately; the forwarded-email answer is merged when it arrives (20 s timeout no longer blocks the screen). Add-card calls untouched.

## Online healthy user
Same screens and results. Differences: imports are saved before upload and the pending card appears only if something is left over; export content comes from the local store (a superset of what the server has plus unsynced rows); counts and duplicate check no longer download history.

## Tests
`test/data/statement_import_autoresume_test.dart` (offline then reconnect, restart before upload, exact-retry replay, 409 park, transport classification), `test/data/local_export_test.dart`, `test/features/import/data_export_offline_test.dart`, `test/features/settings/data_storage_local_count_test.dart`, Find Cards immediate-result test. Existing import review / PDF tests now override the continuation provider (`test/support/memory_import_continuation.dart`) because the flag default changed.

## Known gaps
Park state is in memory (re-learned after restart). Email forwarding, Gmail, IMAP untouched (online by nature). Not run on a device.
