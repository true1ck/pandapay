# WP-C2: queue hygiene and schema foundation

Branch `offline/c2` (based on `feature/offline-first`). Work package C2 of
`docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`. Findings addressed: Q-01, Q-02,
Q-04, Q-06, Q-07, Q-10, Q-11 (registry half), SRV-05 / SRV-06 / SRV-17 (client
halves), W-17 (foreign payments drain), L-10 (schema contention).

## What changed

### 1. Schema foundation

* `AppDatabase._schemaVersion` 2 -> 3. The v3 step adds `attempts`,
  `next_attempt_at` and `parked` (all `INTEGER NOT NULL DEFAULT 0`) to
  `transaction_outbox_entries`. `last_error` already existed since v1. The step
  is idempotent (PRAGMA check first, tolerates the SMS-isolate race) and runs
  after the v2 `payment_method` step, so it also upgrades a pre-v1 outbox.
* New `lib/data/local/local_first_schema.dart` (`LocalFirstSchema`): a module
  schema with its own version row in `local_first_schema_version`, append-only
  numbered migrations, one SAVEPOINT per run, and `ensure(db)` called from the
  `AppDatabase` constructor. A database from a newer app is left alone.
  Rules for future tables are in the file header: `namespace TEXT NOT NULL`
  first primary-key column, additive only, idempotent migrations, register in
  `QueueRegistry`.
* Migration 1 (the only one so far): `transaction_tag_outbox` gets
  `next_attempt_at`, `parked`; `foreign_payments_outbox` gets `attempts`,
  `next_attempt_at`, `parked`, `last_error`. `ensureForeignPaymentsSchema` also
  creates/adds these, because that table is created lazily after the migration.

### 2. Shared retry rule (`lib/data/local/queue_retry_policy.dart`)

`classifyQueueFailure(error)`:

| Class | Errors | Effect |
|---|---|---|
| `network` | `SocketException`, `TimeoutException`, `http.ClientException`, `TlsException`, `AuthenticationUnavailableException`, HTTP 401 | not an attempt, no backoff, the pass ends |
| `retryable` | 5xx, 408, 429, `ApiException` without a status, any other error, plus endpoint-specific statuses (409 for tags and foreign payments) | `attempts + 1`, backoff 30 s, 1, 2, 4 ... capped at 30 min |
| `permanent` | other 4xx | parked (kept with its error, never retried by itself) |

### 3. Transaction outbox (Q-01)

`pending()` returns only due rows (not parked, `next_attempt_at <= now`),
ordered `(parked, next_attempt_at, created_at, id)`. New: `all()` (every row,
used for counts and for rebuilding provisional rows), `parked()`,
`retryParked(id)`, `resetBackoff()`. 20 rejected rows can no longer starve a
21st valid one. The provisional row of a parked entry stays visible.
`pendingOutboxCountProvider` and the sign-out report use `all()`.

### 4. Command outbox (Q-02, SRV-17)

Network errors are not attempts and end the pass. `resetBackoff()` is called
from `outboxFlushProvider` when connectivity returns (also for the transaction
outbox). A plain HTTP 500 for a target that is not a server id (`v2:`,
`projection:`, `local-outbox:`, `local:`) is parked instead of looping every
30 minutes. `commandHandlersFor`: ignore treats 404 and 409 "already
'<state>'" (state matching the reason) as success; restore treats 404 as
success. A 5 minute foreground timer in `outboxFlushProvider` re-evaluates due
work (`outboxDueRecheckInterval`).

### 5. Duplicate-resolution outbox (Q-02)

Network errors no longer count towards the 5-attempt block and end the pass; a
permanent 4xx blocks immediately. There is no time backoff in this queue, so
there is nothing to reset on reconnect.

### 6. SyncEngine (Q-06, Q-07, Q-10, SRV-05, SRV-06)

* Push in chunks of at most 60 KiB / 200 changes, at most 5 requests per sync
  (a longer queue continues through the existing continuation timer). Order is
  preserved. A chunk answered with 413/400/422/500 is halved until the bad
  change stands alone (budget: 24 extra requests per sync): a 413/400/422
  single change is rejected, a single 500 counts one attempt. Anything else
  (401, 403, 408, 429, other 5xx, network) aborts the sync and records nothing,
  as before. A non-200 for one chunk no longer fails all items.
* Applied changes: after the server acks a change it is marked applied
  (`sync_pending_changes.in_flight = 2`), never pushed again, not counted as
  pending. It is deleted only after the fresh server copy was stored
  (`SyncQueue.markApplied / appliedEntities / purgeApplied`). A failed refetch
  leaves it applied, not queued; the next sync (or app run) refetches and
  purges. See "Deviations from the plan".
* `splitRepository.sync` and the foreign-payments sync start after the edit
  push, unawaited, in a `finally`, so a hung or failing one cannot block or
  abort the push, the pull or the next sync, and they still start if the push
  fails. The foreign sync runs only when something is due (it also refreshes
  exchange rates, which a sign-in sync must not do).
* Device recovery: HTTP 409 `{error:'device_not_registered'}` on push or pull, or
  a push where every result is `not_found`/`rejected` (old server), registers
  the device again (`registerDevice(deviceId: current)`) and retries the same
  request once, before anything is rejected. At most once per sync.
* Pull: a 404 for an insert/update change is skipped (`skippedIds`) instead of
  aborting the pass; a server cursor behind the local one
  (`latestServerSeq <= since`) resets the local cursor to 0 and resyncs, but
  only once: if it is still behind from 0 it throws as before (no loop).

### 7. QueueRegistry (Q-11 registry half)

`lib/data/local/queue_registry.dart`. `QueueSpec` (name, table, namespace
column, pending/parked/blocked SQL, extra tables, optional custom count SQL,
kind `outbox` or `localData`) for every queue of appendix B:
`sync_pending_changes`, `transaction_outbox_entries`,
`duplicate_resolution_outbox`, `command_outbox`, `transaction_tag_outbox`,
`foreign_payments_outbox`, `statement_import`, `shared_commands`,
`split_documents`, `v2_outbox`, `sms_intake`, `sms_captured_messages`.
API: `countsFor`, `countAll`, `unsent`, `localOnly`, `hasUnsent`, `allTables`,
`attachFlush`, `flushAll`. Missing tables or columns count as 0. Not yet read by
sign-out, backup or `pendingRecoveryStatusProvider` (WP-C3).

### 8. Tag and foreign-payments outboxes (Q-04, W-17)

Same rule as the transaction outbox, with 409 treated as retryable for both.
`TransactionTagsRepository` and `ForeignPaymentsRepository` gain `now:`,
`resetBackoff()`, `retryParked()`, a parked count; the foreign repository also
`hasDueChanges()`. A later foreign edit waits behind an earlier parked or
backed-off change of the same payment (edits are patches; sending out of order
would let the older one win). Both are reset on reconnect from
`syncLifecycleProvider`.

## Files

New: `lib/data/local/local_first_schema.dart`, `queue_retry_policy.dart`,
`queue_registry.dart`, `lib/data/local_first/command_outcomes.dart`.

Edited: `app_database.dart` (v3 step + `LocalFirstSchema.ensure`),
`transaction_outbox_repository.dart`, `duplicate_resolution_outbox.dart`,
`local_first/command_outbox.dart`, `sync_queue.dart`, `sync_engine.dart`,
`sync_transaction_delta.dart`, `transaction_tags_repository.dart`,
`foreign_payments_repository.dart`, and two anchors in `app/providers.dart`
(`pendingOutboxCountProvider`, `commandHandlersFor`, `outboxFlushProvider`),
plus one line in `account_sign_out_provider.dart` (`.pending()` -> `.all()`).

## Flags and migrations

No flags. Client DB: `user_version` 3 and `LocalFirstSchema` version 1. All
additive; an older app on the same file ignores the new columns and table.

## Behaviour changes an online, healthy user can observe

Intended: none for a healthy session. Differences that exist, all on failure
paths or invisible:

1. A row the server permanently rejects (4xx) is now parked after the first
   attempt instead of being retried at every flush. A transient 5xx on the
   transaction outbox, tag outbox or foreign outbox now waits 30 s+ before the
   next automatic try (before: the next trigger). Resume does not reset it;
   reconnect does.
2. A pure network error ends the flush pass after the first request instead of
   trying every row.
3. The command outbox, transaction outbox and duplicate outbox flush also on a
   5 minute timer while the app is open. With nothing due it does three small
   local SELECTs and no network.
4. `SyncEngine`: split sync starts after the edit push (before: before it,
   awaited). The foreign-payments outbox is now drained by sync when it has
   due changes (before: only when its screen read it).
5. Sign-out/Home pending counts now include rows waiting out a backoff or
   parked (more accurate: they are unsent work).
6. Push over 60 KiB is split across requests (never happens for a small queue).

How verified: `flutter test` on all touched areas (list below), including the
pre-existing tests for the outboxes, sync engine, quick add offline,
portable backup, shared expenses storage, sms_v2 schema and
`performance_guards_test`. The only existing tests edited are:
`transaction_outbox_repository_test` (a failing row is read through `all()`
because it now backs off), `foreign_payments_repository_test` (calls
`resetBackoff()` before the retry, standing in for reconnect),
`sync_transaction_delta_test` (a 404 for an update is now skipped, was an
error), and the hard-coded `user_version` assertions (2 -> 3).

## Deviations from the plan

* Plan: "remove acked rows from the queue BEFORE `_materialize`". Done as
  "mark applied (never re-pushed, not pending) before, delete after". Removing
  the row before the refetch makes the edit visibly revert: the edit screens
  save only to `sync_pending_changes`, the list shows it as an overlay, so the
  stored row still has the old value until the refetch lands (and until the
  next sync if the refetch fails). The existing test
  `successful push persists the accepted row before removing its pending
  overlay` documents the same invariant.
* Plan: "materialize via the delta path". Not done. The post-push refetch is
  still the full `GET /transactions` (and cards). A per-id delta is cheaper
  for a few edits and far more expensive for a 200-row push; switching also
  changes what the complete-query prune sees (L-04), which belongs to WP-C7.
* Tests for the engine, foreign and tag outboxes are in new files
  (`sync_engine_queue_hygiene_test.dart`, `foreign_payments_outbox_hygiene_test.dart`,
  `transaction_tags_outbox_hygiene_test.dart`) rather than the existing ones,
  to avoid merge conflicts; `transaction_outbox_hygiene_test.dart` likewise.
* Statement import is registered as a custom-SQL spec (`statement_import`), the
  only queue that is not the rows of one table.

## Known gaps

* Q-13 (`SyncQueue` constructor resetting `in_flight`) is only partly handled:
  the reset no longer touches applied rows, but a constructor call can still
  return a push that is genuinely in flight to the queue. Left alone because
  restart recovery depends on it.
* No UI lists parked rows yet (WP-C13); `retryParked` exists on every queue.
* Sign-out, backup/restore lists and `pendingRecoveryStatusProvider` do not
  read `QueueRegistry` yet (WP-C3). `providers.dart` `pendingRecoveryStatus`
  still counts `sync_pending_changes` raw, so applied rows (`in_flight = 2`)
  count there until C3 switches it to the registry.
* The 5 minute timer has no unit test (wiring only); the logic it triggers is
  the same `flush()` covered by the outbox tests.

## How to test

```
cd app
flutter test test/data/local test/data/local_first \
  test/data/sync_engine_local_test.dart test/data/sync_engine_queue_hygiene_test.dart \
  test/data/sync_engine_card_materialization_test.dart test/data/sync_transaction_delta_test.dart \
  test/data/transaction_tags_repository_test.dart test/data/transaction_tags_outbox_hygiene_test.dart \
  test/data/foreign_payments_repository_test.dart test/data/foreign_payments_outbox_hygiene_test.dart \
  test/features/quickadd/quick_add_offline_test.dart test/performance_guards_test.dart
```

Migration test: `test/data/local/outbox_retry_columns_migration_test.dart`
(builds a real v2 database, seeds rows, reopens, asserts rows survive, new
columns default and the version is 3) and `local_first_schema_test.dart`.
