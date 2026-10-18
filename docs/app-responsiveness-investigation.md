# App responsiveness investigation — 18 October 2026

> Follow-up implementation: see [SMS capture and sync architecture](sms-capture-and-sync-architecture.md).
> The investigation below records the pre-fix findings; follow-up code changes
> address the central capture pipeline, bulk worker, refresh amplification and
> subscription source selection.

Investigation only: no application behavior, UI, installed package, account, or
device data changed. Repository inspected at `5e03632`. Findings below separate
device evidence from code-level risks; this is not a claim that the entire app
has been stabilized.

## Device evidence

Read-only ADB diagnostics from Motorola edge 50 fusion, `ZA222MS4SF`:

- Installed production package `app.pandapay.pandapay`, version code `20052`,
  version name `1.0.1`, last updated 18 October at **11:19:10 IST**.
- Android's last ANR report records **11:20:59 IST**: input dispatch timed out,
  waiting **10,000 ms for a MotionEvent** in `MainActivity`.
- Process exit history confirms an ANR exit at 11:21:49. This was not reported
  as an out-of-memory kill. Reported RSS was 220 MB; that alone does not rule
  out memory/GC pressure.
- The repository's SMS main-thread correction, `5e03632`, is timestamped
  **11:23:24 IST**, after the installed package update and incident. The
  currently installed binary therefore predates that commit; its precise
  source revision was not embedded/read from the APK.
- `/data/anr` is restricted on this device. The exit report references a
  protected ANR trace. We have the timeout reason, but not the blocked-thread
  stack; SMS is a strong suspect, not a stack-proven incident root cause.
- No live PandaPay process was available when `gfxinfo` was read. Consequently
  there are no attributable frame percentiles from this inspection. A logcat
  skipped-frame message without confirmed app PID is not used as evidence.

## Findings, in priority order

### 1. Installed build performed inbox queries on Android's main thread

Before `5e03632`, `SmsMethodCallHandler.handleGetSmsActions` synchronously called
`smsController.getMessages` and returned all rows from the platform method
handler. Startup/resume reconciliation can call `syncExistingInbox(limit: 0)`;
the first scan can cover the complete inbox. Content-provider I/O and cursor
traversal on the Android main thread can prevent input delivery and explain
the observed ANR mechanism.

The current commit moves the query/cursor traversal to a single worker and
posts the result back to the main thread. It also preserves reconciliation
checkpoints across builds and yields between local capture chunks. These are
already-present corrections, not changes made during this investigation.
Returning a full inbox still entails a large platform-channel result and Dart
allocation/filtering work. Moving the query is necessary but not proof that
startup is smooth.

### 2. Local financial persistence still does synchronous work on Flutter's UI isolate

`AppDatabase` exposes a synchronous sqlite3 `Database`. Providers directly call
`FinancialStore` on Flutter's main isolate; marking a caller `async` does not
move SQL, parsing or JSON encoding off that isolate.

`FinancialStore.saveTransactions` reads/decodes the entire account transaction
history and JSON-encodes it before a save, then repeats the full operation after
the save to decide whether to notify. It also loops over existing rows for
complete-query replacement and writes rows individually inside a transaction.
Small incoming changes therefore do work proportional to total history.

`transactions()` separately selects every transaction payload/observation time
even for a date-filtered read, before another entity query decodes the rows
actually needed. Several report providers request overlapping histories.
`cachedTransactionById` also loads all transaction entities to find one ID.

The database has a 5-second synchronous busy timeout. WAL improves reader/writer
concurrency, but competing foreground/background writers can still make a UI
isolate write wait. No lock timeout was captured on the phone in this inspection.

### 3. SMS acknowledgements produce unnecessary transaction refreshes

`FinancialStore.discardProvisional` always calls `_notify(ns)`, even when its
DELETE changes zero rows. `onSmsUploaded` calls this for confirmed/duplicate/
ignored messages, individually, outside `store.batch`.

`_financialChanges` and `loadTransactionsWithOfflineCache` invalidate providers
on transaction revision events. Thus an acknowledgement of an already-known
message can trigger report/history recalculation even though displayed data
did not change. The code establishes redundant notifications; exact rebuild
counts depend on Riverpod scheduling and must be measured rather than assumed
to equal one rebuild per message.

The inbox path captures the full scan locally before uploading. Each network
batch then invokes capture again through `logTransactionsFromSmsBatch` and
fetches a confirmation transaction range. Local capture batching reduces
notifications but still repeats parsing, card reads and SQL for known messages.

### 4. Refresh paths amplify each other

`homeDataRefreshProvider` starts wallet, catalogue, categories, overrides, Home
summary, transactions and eight secondary display warm-ups together. Resume
invalidates that provider without a shared lifecycle debounce. SMS, split sync,
ordinary sync and display refresh have separate coordination mechanisms.

`SyncEngine._pullAndApply` materializes entities and invalidates displays for
each pull page. For a transaction page, materialization fetches the complete
transaction list; a multi-page backlog can repeat that whole-history fetch and
save. `_invalidateFor` also invalidates `homeDataRefreshProvider`, starting the
broad refresh path alongside the materialization work.

Successful transaction/card/budget/override/sync-push mutations mark every
account cache key stale. That is broader than the entity actually changed and
can defeat the normal 15-second display-cache freshness guard.

These are request/CPU/I/O amplification paths. Network waits alone do not block
the UI thread, but result processing, writes and dependent rebuilds can.

### 5. Subscription flicker has a concrete source-selection problem

`recurringReportProvider` prefers `_buildLocalRecurringReport` whenever any
provisional transaction is pending, even if a valid server recurring report is
already cached. When pending rows clear, it can return the server report again.

Those sources are not equivalent:

- Local detection requires a subscription-like category, at least three local
  charges, and uses its own grouping/cadence rules.
- The API returns persistent active, non-dismissed `recurring_series`, including
  parser-created records with stored renewal metadata.
- Local detection does not read the server's persisted dismissal/series state.
- Partial local history and provisional rows can be missing the evidence or
  category needed by local detection.

Consequently a nonempty server subscription report can become empty while an
unrelated SMS is pending, then reappear after reconciliation. This is a
code-confirmed possibility matching the symptom, not a reproduction with the
user's private report data. The fix must preserve established series and
dismissals, rather than relaxing detection rules or hiding genuine deletions.

### 6. A sign-in does not reset all work or demonstrate session health

Financial data is intentionally scoped to account identity, not access-token
rotation. Signing back into the same account can reuse its local history and
pending work; an app update also preserves those records. That is desirable for
durability and means reinstall-style cleanup is not an appropriate remedy.

Inbox checkpoint/count keys are currently device-global, while the repair key
is account-scoped. Account switches deserve explicit regression coverage: one
account's checkpoint must not suppress another account's initial recovery, and
server-count changes must not cause unnecessary complete inbox scans.

The HTTP client already uses the live access token and coordinates concurrent
401 refreshes. Existing documentation identifies an unresolved server-side
refresh-rotation/lost-response risk. No API/auth request trace was collected
here, so this investigation cannot establish that today's session refresh
failed or that authentication caused the ANR.

## Stabilization sequence without UI or feature changes

1. Verify a build containing the native SMS worker correction on the same phone,
   preserving app data. Record the source revision in build metadata.
2. Batch SMS confirmation changes and notify only when displayed entities
   actually change; skip redundant local recapture of known durable messages.
3. Replace whole-history before/after serialization with row-level change
   detection, targeted lookups and metadata queries. Keep receipts, pending
   edits, account isolation and complete-query deletion semantics intact.
4. Move bulk persistence/parsing onto a dedicated database worker with explicit
   cross-isolate notifications. A broad migration needs regression coverage;
   merely adding `async` or lowering busy timeout is not a substitute.
5. Coordinate lifecycle refreshes, invalidate only affected entities, and avoid
   fetching full transaction history for every sync pull page. Cursor advance
   must still wait for durable materialization.
6. Keep the last valid subscription series visible through unrelated pending
   writes. Align local/server rules and preserve dismissal state before using
   local detection as a replacement.
7. Scope reconciliation checkpoints to account identity with a safe migration.
   Investigate session rotation separately using redacted correlated server
   diagnostics; never clear local financial data to mask the problem.

## Required verification before calling this stable

Existing focused regressions run during this investigation: **38 passed** across
`financial_store_test.dart`, `local_first_sms_test.dart`,
`session_keepalive_test.dart`, and `home_screen_test.dart`. These validate existing
storage/SMS/session/Home behavior; they do not measure device frame performance
or prove the absence of the redundant notifications described above.

- Profile the same phone with its existing data: cold launch, warm resume,
  scrolling/taps during inbox recovery, Wallet, Payments due, Subscriptions and
  Insights. Measure Flutter UI/raster frame timings and input latency as well
  as Android ANRs; unit tests cannot establish smoothness.
- Exercise large inbox/history, no-op duplicate replay, multi-page sync,
  offline/online transitions, background SMS, storage contention, expired-token
  refresh and same/different-account sign-in.
- Verify no transaction loss/duplication, correct reward cycles, pending-edit
  survival, durable cursor advancement and unchanged established subscriptions
  while unrelated SMS work is pending.
- Compare against a known-good revision using equivalent data/network state in
  a controlled test environment. Do not downgrade or erase this phone's data.

This investigation does not install a build, interact with private screens,
change production services, or claim an end-to-end performance validation.
