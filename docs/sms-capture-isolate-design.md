# SMS v2 capture isolate: design note (7 Nov 2026)

Status: implemented in `perf-c-capture-isolate`. Rule R1/R9 of
`docs/PERFORMANCE_RULEBOOK.md`: the 5 Nov SMS v2 switch (`0364192b`) deleted the
18 Oct capture isolate (`docs/sms-capture-and-sync-architecture.md`). This puts a
database-owning worker back, without touching parsing, classification or ledger logic.

## Decision: full isolation, not the subset

The whole `SmsImportStore.captureBatch` -> `SmsV2Pipeline.processBatch` chunk runs in
the worker, because I checked that nothing in it reads UI-isolate-only state:

* every store it uses (`FactStore`, `EventStore`, `LedgerStore`, `InstrumentStore`,
  `OutboxStore`, `StatsStore`, `SyncStateStore`, `ProjectionWriter`, `ForeignPaymentBridge`,
  `SmsIntakeRepository`, `SmsLearningFeedback`, `CategorySnapshot`) takes only a
  `Database`/`FinancialStore` and a namespace;
* the only process-wide caches are `Expando`s keyed on the `Database` object
  (`FactStore._caches`, `BundleStore._verifiedByDb`) and a static set in
  `SmsIntakeRepository`: per isolate, so a second connection simply has its own;
* `FactStore` caches are insert-only decoded copies of immutable facts, so a UI cache that
  never saw a worker-written fact just misses and reads the row. `FinancialStore` keeps
  no entity cache (only a migration-done set and a row-count fingerprint that changes
  after worker writes). Nothing needs invalidating except the change notifications below.

## What crosses the boundary

In (per 200-message chunk, plain data only): namespace, appVersion, `categoryIdBySlug`,
a capture-session id, bundle hash, the shared `RuleBundle` as a JSON string (sent once per
distinct bundle per worker; encoded once per bundle object on the UI side), and the chunk
as `[backfill, [[sender, body, receivedAtMicros, isUtc]...]]` groups. The history/live split
(`receivedAt` older than `clock() - 1 day`, or the explicit `backfill`) is decided on the
UI isolate with the runtime's clock, so tests with a fake clock behave identically.

Rebuilt in the worker from its own connection, once per capture session: the provisional
overlay (`ProvisionalStore.overlay`), `PersonalRuleEngine`/`PersonalRuleStore`,
`InstrumentStore`, `CategorySnapshot` (per chunk, as today). The compiled bundle is cached
per (bundle hash, overlay revision) so `RuleEngine`'s `Expando` compile cache is hit.

Out: the set of changed entity names collected by the worker's `FinancialStore`
(`onEntityChanged`: `observations`, `needs_review`, `transactions`, `foreign_payments`,
whatever the pipeline wrote), the number of processed messages, or an error string.
Nothing else, no model objects.

## One code path

`runCaptureChunk` (pipeline/capture_executor.dart) is the exact old loop body (category
snapshot, pipeline construction, `[history, live]` groups, `SmsImportStore.captureBatch`).
The in-process executor and the worker both call it, so results cannot drift. In-memory
databases (all tests, `filePath == null`) use `InProcessCaptureExecutor`, which still
yields with `Future.delayed(Duration.zero)` between chunks.

## Connection, locking, contention

The worker opens `AppDatabase.openFile(path, keyHex: db.keyHexForWorker)` (WAL and
`busy_timeout = 3000` come from the `AppDatabase` constructor; tests use the unencrypted
test opener like `FinancialReadWorker`).

* Readers never block writers in WAL; the UI connection keeps reading during a chunk.
* Each group runs in `BEGIN IMMEDIATE ... COMMIT` (the pipeline's savepoints nest inside).
  A deferred transaction that read first and then wrote could fail instantly with
  `SQLITE_BUSY_SNAPSHOT` when the UI connection committed in between; taking the write lock
  up front makes the worker wait (busy_timeout) instead.
* Writers serialize via SQLite. A UI write issued while a chunk commits waits up to 3 s on
  the UI isolate, then throws `SQLITE_BUSY`. That is the cost of two connections and the
  same trade the 18 Oct design made; it is bounded by one chunk of work, which previously
  blocked the UI for the same time with no way to interleave. Risk to verify on a phone.
* No deadlock: each side holds at most one connection's lock and neither waits on the other
  while holding it; the worker never calls back into the UI isolate mid-transaction.
* Account recovery (`withRecoveryDatabase`) cannot see another isolate's handle, so each
  job holds an `AccountRecoveryOperationGate` admission until its reply or the worker's exit
  (not merely until a caller-side timeout).

## After commit: UI invalidation

The UI forwards the worker's changed-entity set with `financial.notifyExternalChanges`
(the same revision streams the in-process path emitted, after commit, never before). The
callback runs when the reply arrives even if the caller already timed out, so a slow but
successful job never leaves stale providers. A failed job still forwards what its earlier
groups committed.

## Account fencing, cancellation, errors

* `accountIsCurrent` is checked before dispatch and after the reply. After a reply for a
  changed account the notifications are still forwarded (cheap, idempotent) and capture
  throws `SMS account changed`, so no later chunk is sent. A chunk the worker already
  started finishes and commits under its own namespace, exactly like a synchronous chunk
  that started before sign-out: rows, decisions and acknowledgements are atomic and
  namespaced, so nothing leaks into another account.
* No hard kill. A killed isolate would leave its connection and write lock open until GC.
  Cancellation is cooperative: the caller stops sending chunks; the worker is serial.
* Worker exception: `ROLLBACK`, error reply, `capture` rethrows. The messages stay in
  `sms_intake` (acknowledge happens inside the same transaction) and `_sync` retries.
* Worker death / timeout (90 s per chunk): pending requests fail, nothing is acknowledged
  by the UI, the next `capture` respawns. If the dead chunk had in fact committed, replay
  is a no-op (`sms_source_decisions` dedup), the same guarantee as a crash today.
* Worker cannot start (spawn/open failure): that chunk falls back to the in-process path,
  so a broken worker degrades to today's behaviour instead of stopping capture.
* Idle: the shared per-database worker closes itself after 2 minutes without a job.

## Code map and tests

* `pipeline/capture_executor.dart`: request types, `CaptureExecutor`, `runCaptureChunk`,
  `InProcessCaptureExecutor`, `FallbackCaptureExecutor`.
* `pipeline/capture_worker.dart`: `SmsCaptureWorker` (isolate, protocol, shared pool) and
  `PooledCaptureExecutor`. `SmsV2Runtime.capture` only builds requests and picks the
  executor (`captureExecutor:` override, else worker for file databases, else in-process).
* `test/features/sms_v2/pipeline/capture_worker_test.dart` (file-backed temp database):
  byte-identical tables vs the in-process path (wall-clock columns and random instrument
  UUIDs normalised), UI connection sees rows plus revision notifications, injected
  throw / isolate death / stall leave messages pending, account change after a chunk stops
  later chunks, start failure falls back, recovery admission held while a job runs.

## Deferred / not done

* The pre-capture `InstrumentSeeder.seed` stays on the UI isolate (O(cards), once per
  `capture` call). Rule-bundle load/verify stays on the UI isolate (R9 item 5).
* `SmsImportStore` callers without a pipeline (live SMS receiver, iOS handoff) are
  unchanged: they only append to `sms_intake`.
* Phone measurement (R10) is not done here.
