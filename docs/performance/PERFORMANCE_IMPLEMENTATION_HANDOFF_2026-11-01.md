# PandaPay remaining performance work — implementation handoff

Prepared 1 November 2026. Planning review reference: `e7a44bdd` on `codex/ios-shortcuts-prototype`. Re-read HEAD and the worktree before executing: other sessions are actively changing this branch.

Review record: two agents independently inspected networking/background work and data/worker architecture before drafting. The networking agent subsequently reviewed this document's P0–P2 and approved it with a deadline/fence clarification, now incorporated. The data agent supplied the paging/worker invariants but its final document rereview ended at a usage limit; that final independent rereview is pending. No application implementation or runtime verification was performed as part of preparing this handoff.

## 1. Purpose and boundaries

Reduce authenticated process-cold launch delay, first-visit/button latency, scroll stalls, and Activity/Spending refresh flicker. Preserve financial correctness, sessions, account isolation, existing layouts, and the SMS capture pipeline. Images, image compression, visual redesign, and speculative renderer changes are outside implementation scope. Native/renderer tracing remains necessary to identify where time is spent.

This document is an execution specification, not a claim that these changes or tests are complete. Existing history and historical timings are in `EXECUTION_PROGRESS.md` and `EMULATOR_PERFORMANCE_QA_CHECKLIST.md`. Reproduce current behavior before using their old numbers as a baseline.

Use the lower-cost model available in the user's model picker for bounded implementation packets. The phrase “Luna 5.6 high” is not a verified selectable model identifier in this session. Do not claim to switch to it or invent pricing/token savings. Multiple agents duplicate some context; use short packet prompts, limited file scope, and compact evidence reports to control that overhead. Keep architecture approval and financial-integrity review with the lead reviewer.

Deliver planning first. During implementation, finish each packet through tests and review before beginning its dependent packet. Do not repeat the entire audit for every packet.

## 2. Source findings to preserve

| Requested item | Current source evidence | Remaining deliverable |
| --- | --- | --- |
| Cold launch and scroll instrumentation | Dart/native startup markers and historical reproductions exist; Home shell and lifecycle startup were deferred | Correlated native, Dart, presented-frame and input-response measurements on the same artifact |
| Bounded background work | Startup scheduler coalesces keys; transaction/duplicate outboxes cap at 20; sync has bounded push/page counts | Elapsed-time limits, continuation, account-generation cancellation, fairness, and removal of broad repeated maintenance |
| Network deadlines | Endpoint-specific timeouts exist; shared authenticated transport has unbounded send/body/refresh paths | Explicit policies, bounded response handling, cleanup and safe cancellation |
| Transaction history | `/transactions` returns all matching rows; repository/query single-flight exists | Additive paging, explicit partial coverage, one refresh owner, incremental sync materialization |
| DB and JSON work | Raw synchronous sqlite3 and JSON materialization execute in the caller isolate | Measured asynchronous command boundary and eventual exclusive DB-worker ownership |
| Activity/Spending computation | Activity tiles are lazy, but grouping/totals/row metadata still build over history; Spending groups/sorts derived data | Account/query/revision-keyed immutable projections with bounded cache and unchanged UI |
| Acceptance testing | Historical focused, backend and device results exist | Repeatable current-build regression and device evidence, with unresolved failures accounted for |

Correct a stale earlier diagnosis: `outboxFlushProvider` currently calls `startup.cancel('outbox-flush')` during disposal. Test that behavior before adding more cleanup. `cancel()` removes queued work; it does not cancel an already running operation. A scheduler running asynchronous callbacks still runs synchronous callback code on the UI isolate.

## 3. Lead architect and agent ownership

The lead owns the dependency decisions, integration, evidence ledger and final review. With four total agent slots, run at most three workers alongside the lead. Only one worker may own emulator/ADB activity or run Flutter tooling at a time on this Windows setup.

| Wave | Agent A | Agent B | Agent C | Lead |
| --- | --- | --- | --- | --- |
| 0 | Transport/source review | DB/paging contract review | Baseline/tests inventory if slot available | Freeze task scope; record dirty files and shared ownership |
| 1 | NET deadlines | API opt-in paging | QA harness and startup trace tooling | Approve contracts; integrate scheduler fixes sequentially |
| 2 | STORE partial-page semantics | JOBS/SMS bounded slices | UI pure projection modules | Own `providers.dart` and sync coordinator wiring |
| 3 | WORKER command seam and staged migration | Incremental sync implementation after contract approval | Widget/provider regression coverage | Integrate migrations; audit all direct DB users |
| 4 | Review fixes | Backend regression checks | Single QA owner runs device matrix | Final review, scoped commits, remote comparison and push |

Existing dirty SMS/AI/recurring/subscription changes belong to their owners. Inventory them; coordinate overlapping changes. Do not reset, broadly stash, format unrelated files, or stage the entire checkout. Keep `providers.dart` under one integration owner. Workers should add isolated modules and supply integration instructions instead of concurrently editing it.

## 4. Invariants and contract decisions

1. Local rows render before a network refresh when an authorized account snapshot exists. A session-presence hint can select a shell but cannot authorize private data or bypass biometrics.
2. Every asynchronous job, page, worker command and publication carries an account namespace and monotonically changing session generation. Logout and login to the same account must invalidate old work too.
3. Persist changes, receipts and cursor in the appropriate durable transaction before publishing revisions or acknowledging server work. Never hold a SQLite transaction across a network await.
4. A partial page is never a complete query snapshot. Missing rows on a page never imply deletion. Pending local mutations, provisional SMS, receipts, user edits and tombstones survive refresh.
5. Timeout of a mutation means outcome unknown. Preserve its original mutation/idempotency key; reconcile before replay where required. Do not add blind automatic mutation retries.
6. Do not close a shared HTTP client to cancel one request. Do not pass a DB handle, Riverpod ref, widget, callback or active transaction across isolates.
7. `async`, `Future`, and zero-duration delays do not move synchronous CPU/SQLite work to another isolate.
8. Counts/timings may be logged; tokens, OTP, SMS content and financial row payloads may not.

Paging decision for the first release: opt-in pages perform non-destructive upserts only. Do not introduce absence cleanup from keyset paging. Preserve existing complete-response consumers until migrated. Authoritative deletion comes from verified sync tombstones or a separately designed consistent snapshot. If neither is supported by the actual sync payload, final reconciliation remains an explicit open dependency; never silently present the architecture as complete.

## 5. Work packets

### P0 — reproducible baseline and test harness

Owner: QA worker; lead integrates startup instrumentation.

Files: `app/lib/main.dart`, `app/lib/app/startup_timing.dart`, router/Home timing sites, Android `MainActivity`, existing performance docs and new scripts under `scripts/` as needed. Discover actual paths before editing.

- Inventory SDK/process locks and select the working Flutter invocation. The normal Windows wrapper has previously hung; inspect `TOOL_SETUP_REPORT.md` and verify the direct tools snapshot invocation locally if needed. One Flutter process at a time. A command with no completed result is inconclusive.
- Record baseline SHA, dirty-file inventory, artifact SHA256, build mode, package, version, backend, serial, OS, refresh rate, renderer, account/data counts, thermal state and network state.
- Correlate launch intent/process creation, Activity creation, engine/plugin setup, Dart main, preference/session restoration, local DB ready, Home build, presented Home and first input response. Distinguish Flutter first-frame callbacks from actual Home presentation.
- Trace DB query/write/repair, JSON decode, projection, queued/running jobs and network counts using request/run IDs. Instrumentation must have bounded overhead and no sensitive payloads.
- Reproduce force-stop, verify PID absent, then relaunch without clearing data. Also reproduce Recents swipe separately because it may leave the process alive. Capture 10 authenticated samples and the first Home down/up reversal.
- Inventory every route reachable from router/menu links for page coverage; five bottom tabs alone do not cover the application.
- Re-run existing failing suites on a fixed clock. Categorize current failures with exact names and failure output. Old counts such as “26 failures” are historical until reproduced.

Acceptance: usable authenticated Home verified in UI hierarchy, correlated traces and raw sample table saved. Onboarding or startup-error UI cannot pass authenticated startup. If login handoff is required by current `AGENTS.md`, request it and continue independent code/unit-test work meanwhile.

### P1 — NET: centralized timeout policies

Owner: networking worker. Files: `app/lib/data/authenticated_http_client.dart`, its tests, new request-policy helper, explicit long-operation call sites after inventory.

- Inventory headers/body/outer repository deadlines, uploads, downloads, imports and backup/recovery. Retain intentional endpoint budgets.
- Introduce injectable policies for header timeout, body inactivity, overall deadline and refresh timeout. Configure defaults after inventory; initial candidates for ordinary reads are 15s headers, 15s inactivity and 30s overall. Long operations get explicit larger policies. These are proposed tuning values, not measured standards.
- Bound initial request, 401 body buffering, shared refresh and retry. The overall deadline does not restart on retry. Bound maximum response sizes per operation where buffering is used.
- Preserve shared refresh semantics: timing out one waiter must not invalidate another legitimate caller's session. Underlying cancellation must settle before releasing mutation admission when recovery depends on absence of writes. A bare `Future.timeout` does not cancel transport or prove no server-side effect.
- Ensure body completion/error/cancellation releases recovery admission exactly once. If the transport cannot safely abort, expose uncertain completion and retain the appropriate recovery fence until settled; do not claim cancellation support from a timeout alone.
- Do not add automatic retries beyond existing authorized refresh/retry behavior.

Tests: stalled headers; stalled/slow-progress body; refresh stall; 401 retry overall deadline; concurrent refresh; account switch during refresh; long-operation override; admission cleanup; unsupported cancellation and unknown mutation outcomes. Use controlled streams/fake time rather than real 15-second sleeps.

Done: transport/recovery tests pass, existing repository policies remain compatible, no indefinite ordinary request, cancellation limitations documented.

### P2 — JOBS/SMS/OUTBOX: bounded cooperative work

Owner: lifecycle worker; lead alone edits integration in `providers.dart`.

Files: `startup_work_scheduler.dart`, SMS scanner/coalescer, transaction/duplicate/SMS outboxes, sync lifecycle, respective tests.

- Replace nested broad rerun loops with typed reasons: inbox capture, upload, AI-result reconciliation, notifications and display refresh. Coalesce only equivalent work. Record requested/running/due state per account generation.
- A job failure or stall cannot indefinitely starve unrelated jobs. Use P1 deadlines, bounded queue lengths, fairness, retry backoff with jitter, and explicit continuation. Manual/live capture receives priority without an unbounded bypass queue.
- Keep the 20-row outbox batch initially. Add due-at/attempt policy, elapsed-pass checks between operations and continuation while backlog remains. Do not wait for another resume event to discover the next 5 rows.
- SMS scanner already has provider-ID checkpoint, fixed scan head, capture-before-checkpoint and 35ms page yields. Add a slice result: `{captured, scanned, boundary, hasMore, runId}`. Keep a fixed head across continuation; check page/time budget between durably captured pages. Start with two pages per foreground slice, then measure.
- New SMS arriving beyond the fixed catch-up head goes through live capture or the next scan. Provider reset, ID gaps and denied permission must not advance a misleading checkpoint.
- Retain sync push/page caps while adding elapsed budgets and durable continuation. Stop scheduling obsolete account-generation jobs, and fence any completion already in flight.
- Queued-job cancellation, running-operation cancellation and durable resumption must be separate explicit states.

Tests: 25 outbox rows as 20+5; stalled first request; duplicate trigger storm; startup+resume+reconnect; 10k SMS across slices; process death before/after checkpoint; live arrival during catch-up; repeated SMS; OTP ignore; offline capture; account switch; same-account relogin; disposal; permanent error backoff; no starvation; no uncontrolled broad second pass.

Done: each operation has count/time ownership, no missing continuation, no duplicate financial records, no account crossover. A queue by itself is not proof of UI isolation.

### P3 — API: opt-in transaction paging

Owner: API worker. Files: transaction route in `api/src/index.js`, extracted paging helper, route-contract/Postgres tests; migration/index only if query-plan evidence justifies it.

- Preserve current unpaged response for existing clients. Add explicit opt-in `pageSize`/`cursor` fields using the route's naming conventions. Suggested default 200, hard maximum 500.
- Return existing transaction rows plus additive `pageInfo: {nextCursor, hasMore}` for opt-in calls. Query `pageSize + 1`, return at most pageSize. Use `(occurred_at DESC, id DESC)` ordering and keyset comparison.
- Validate dates/limits/cursor versions and bind cursor interpretation to authenticated account, normalized filters and ordering. A cursor is never authorization; every page remains RLS/user scoped. Use an opaque encoded/signed server-controlled format consistent with existing infrastructure.
- Retain category replacement/tag filters/status semantics. Bound tag attachment work to the page. Verify inclusive date/time-zone behavior matches reports.
- Keyset paging over mutable records is not a consistent snapshot: document that inserts/edits/deletions can move rows. First implementation therefore performs no absence-based deletion. Use sync reconciliation for authoritative changes.
- Check `EXPLAIN (ANALYZE, BUFFERS)` on representative local data before adding an index; record existing index coverage.

Tests: legacy contract unchanged; >500 rows; equal timestamps; next-page boundaries; malformed/cross-account/cross-query cursors; limits; dates; custom categories/tags; concurrent insert/edit/delete; no duplicates within unchanged snapshot; no implied completeness during mutation.

### P4 — STORE/REFRESH: safe local-first pages and one refresh owner

Owner: data worker; lead integrates providers and sync consumers.

Files: `financial_store.dart`, `user_cards_repository.dart`, transaction-cache/single-flight tests, new refresh coordinator module, and provider integration.

- Add explicit page application and coverage states (`partial`, `complete`, `stale`, generation/watermark where supported). A partial upsert may not call `saveTransactions(completeQuery: ...)`.
- Preserve old history, pending edits, source receipts and provisional reconciliation while pages arrive. Persist page progress only after durable application. Interrupted refresh resumes safely without falsely marking complete.
- Add SQL order/limit for local reads with stable cursor, returning coverage and revision. Empty page, empty query, offline partial history and fully synchronized empty history remain distinguishable.
- One coordinator per account/session/query owns network work and completion. Equivalent Home/Activity/report/sync callers share the owner; different filters stay independent. Completion means committed refresh, not merely returned cached rows.
- Emit one revision per committed batch and avoid invalidation loops that immediately fetch again. Recheck generation after every await and before write/publication. Dispose coordinator resources.
- Audit compatibility JSON-cache readers before removing duplicate encode/write paths. Remove only after canonical-store behavior and offline fallback tests pass.
- Keep spending totals based on complete aggregate semantics, never the number of visible/paged rows. Search/tag filtering cannot silently search only a partial page. Update aggregate/export/card-utilization consumers explicitly.

Tests: first page cannot delete older rows; interrupted paging; known-empty coverage; offline partial coverage; concurrent consumers share one request/apply; independent queries; refresh failure/retry; account and same-account session switch; totals/tags/refunds/reversals/deleted/pending rows unchanged.

### P5 — SYNC: incremental authoritative materialization

Owner: data/sync worker after P4 contracts; review by architect.

- Inspect existing pull change payload and server entity retrieval first. Prefer the existing sync protocol over introducing a competing delta service.
- Replace `_materialize` unfiltered `fetchTransactions()` with bounded affected-ID payloads or entity-by-ID batches if server change records support them.
- If payload lacks required version/tombstone information, add a backward-compatible capability with tests before switching consumers. Handle local-only source facts and account clear/recovery operations explicitly.
- Entity application, receipts and pull cursor are atomic at the correct batch boundary; server acknowledgment follows local commit. Coalesce revisions after application.
- Initial bootstrap may still need paged history; normal resume/reconnect after one new transaction must not refetch all history.

Tests: one changed transaction in a 10k-row account; edits/deletes/tombstones; interrupted commit; lost acknowledgement; replay; permanent rejection; reordered/duplicate batches; account switch; no cursor beyond unapplied state; totals reconcile with authoritative server state.

### P6 — WORKER: move DB/JSON/materialization off UI isolate

Owner: DB worker; architect approves each ownership step. Highest-risk packet; do not implement by wrapping current calls in `async`.

- Inventory every `.db` access and canonical-store consumer: FinancialStore, SMS intake/rules/receipts, sync/outbox, tags/cards/commitments, backup/recovery leases, namespace clear and account erasure. Produce a migration checklist.
- Define an async facade before moving ownership: `readTransactionPage`, `readAggregate`, `applyTransactionPage`, `applySyncBatch`, `captureSmsSlice`, `mutateOutbox`, `clearNamespace`, `freezeForRecovery`, `close`. Commands carry requestId, namespace, sessionGeneration and serializable arguments; results carry revision/coverage/error codes.
- Use one long-lived worker with explicit bounded command admission, priority/fairness and startup/health/close protocol. Worker owns SQLite opening, migrations, repairs, canonical reads/writes and associated heavy JSON conversion. Return bounded DTOs; a 10k-object copy can still stall the receiver.
- Transfer command ownership in small coherent slices. A temporary hybrid must have explicit transaction/locking rules; do not open a second connection casually or call the DB exclusively worker-owned while raw UI consumers remain.
- Remove read-triggered broad repairs only after equivalent versioned maintenance is reliable. Schedule bounded repairs once per relevant version/account, preserving user corrections and migration semantics.
- Recovery/backup needs quiescence of queued and running writes, not merely a frozen provider. Preserve existing leases, WAL/backup correctness, failure rollback and account-erasure behavior.
- Handle worker failure with typed errors and restart/replay of durable work. Never replay a mutation with a new identity. Do not silently fall back to heavy synchronous UI work.

Tests: command ordering; queue saturation; failed SQL rollback; worker restart; process death; recovery freeze; safe close; migrations; namespace deletion while commands wait; same-account relogin; SMS/outbox/sync ordering; old/new financial result equivalence. Profile 3k/10k rows during gestures to prove actual isolate ownership.

### P7 — UI: memoized Activity and Spending projections

Owner: UI worker; no layout or image changes.

Files: `activity_screen.dart`, `spend_trends_screen.dart`, extracted pure projection modules and provider/widget tests.

- Extract Activity grouping, totals, flattened row metadata and tag lookup from `build`. Retain existing `ListView.builder` and stable keys.
- Extract Spending category/payee grouping, totals and sorting. Precompute group totals used by comparators instead of folding repeatedly inside a sort.
- Memoize immutable results using account + session generation + normalized query + transaction revision + tag/category revision + relevant calendar/time-zone/locale inputs. Use a bounded LRU/provider lifecycle; no unbounded all-query global map.
- Keep selection/expanded-row UI state separate from history projection so toggles do not rebuild O(n) aggregates. Selection totals should use indexed rows rather than rescan history when practical.
- Preserve previous content only for the same authorized account generation and query. Account/filter changes cannot flash old results. Handle midnight/period boundary and tag edits without stale values.
- If measured projection CPU remains high, move pure projection work to the worker contract; do not spawn an isolate on every build.

Tests: identical dependencies reuse projection; revision/query/tag/account/clock changes invalidate correctly; bounded eviction; financial equivalence; no first-visit errors; unchanged labels/layout/interactions; selection/bulk actions/detail edits; explicit-refresh flicker; disposal and stale completion. Benchmark 3k/10k without enforcing brittle host-millisecond thresholds.

## 6. QA scenarios and provisional acceptance

Targets below are project acceptance proposals to validate on supported device tiers, not universal Flutter guarantees. Record raw samples, p50/p95/max and failures; never average away a 7–10s outlier. Ten launches give limited percentile confidence, so retain all ten and repeat noisy comparisons.

| ID | Scenario | Required correctness / evidence | Initial target |
| --- | --- | --- | --- |
| ST01 | Authenticated process-cold launch, 10 runs | PID gone; same account; visible Home and first input response; Android and Dart timings | Home presentation p95 <=3s, max <=5s; any >5s gets a trace and remains open |
| ST02 | Background 5 minutes, resume; separate process-death run | Session preserved; local content usable during expired-token refresh | Warm response p95 <=750ms; process-death follows ST01 |
| NAV01 | Every discovered route, first and repeat visits | Correct route/account/data; no unexpected error/blank/indefinite spinner | Heading p95 <=1s, useful interaction <=2s with available cache |
| SC01 | Home bottom/top reversal, 5 cycles | Bounds move both ways; concurrent sync and SMS traced | No input stall >100ms; 60Hz UI/raster p95 <=16.67ms, p99 <=33ms, frame misses <5% |
| SC02 | Activity/Spending scroll, refresh, filters and selection | No duplicate rows, lost selection or heading flicker; totals valid | Same frame targets; 120Hz tier uses 8.33/16.67ms budgets |
| SMS01 | Live valid SMS, duplicate, OTP, background delivery | Durable capture; one financial row; OTP ignored; checkpoint valid | No UI stall; counts and latency recorded |
| SMS02 | 10k inbox catch-up plus new live message | Bounded/resumable; no loss at fixed head or process interruption | Bounded queue growth and visible input response |
| SY01 | 3k/10k history, large outbox, reconnect storm | One refresh owner; durable cursor/receipts; bounded continuation | No foreground DB/JSON span >50ms; aim <8ms chunks before worker migration |
| NET01 | Offline, slow/stalled headers/body, timeout, 401 | Cached view usable; mutations retain identity; retry can recover | Every operation completes/errors within configured policy |
| AC01 | Logout/login to other and same account during work | No old rows/publication/jobs across session generation | Zero cross-account or old-session data |
| DB01 | Kill during apply, resume; backup/recovery and clear | Replay safe; cursor never ahead; recovery fence intact | Identical financial results after replay |
| REG01 | Forms, add/edit/delete/restore, imports, wallet, settings, backend builds | Existing behavior and financial totals preserved | All relevant tests pass; no unexplained full-suite failures |

NET01's deadline is caller-facing completion. An uncertain mutation's reconciliation and recovery fence may outlive that deadline until its transport settles; never release that fence just to satisfy a latency target.

Measure Flutter frame timing/trace and Android evidence together. `gfxinfo` alone may not account for Flutter frames consistently across renderers. Emulator GPU/raster issues must be reported separately from physical results; do not infer which layer is slow from a Dart callback alone.

Device safety: read current `AGENTS.md`. Emulator local profile build uses API `http://10.0.2.2:4001`, auth `http://10.0.2.2:3210`. Physical production testing uses the documented hosted endpoints and existing account; do not inject synthetic financial test messages into a real production account. Use the isolated emulator test account for synthetic scenarios. Recheck exact installed version/signing certificate/backend before each build; install a strictly higher version with `adb install -r`. Never uninstall, use downgrade flags, `pm clear`, or wipe data. Manual authentication handoff remains required where applicable. Artifact build success alone is not device verification.

## 7. Completion ledger and reporting contract

Create/update a small ledger after every packet with:

`packet | owner | base SHA | files | status | command + exit code | evidence path | remaining dependency | reviewed by`

Allowed status: not-started, in-progress, implemented-unverified, verified, blocked. Store current values, not optimistic percentages. Existing implementation counts must be rechecked before copying into the ledger.

Each worker's final report is limited to: change and reason; exact files; tests with completion/exit code; evidence path; unresolved risk. Do not send full source or logs unless diagnosing a failure. Reuse this plan and packet IDs instead of forwarding the full chat.

Suggested implementation prompt:

> Read AGENTS.md and docs/performance/PERFORMANCE_IMPLEMENTATION_HANDOFF_2026-11-01.md. Implement packet P[N] only. Inspect current HEAD and preserve pre-existing edits. Follow its ownership boundary and invariants. Add focused regression coverage, complete the relevant tests, and report file paths, commands, exit codes, and unresolved dependencies. Mark uncompleted/hung checks explicitly. Do not edit providers.dart unless you are its designated integrator. Do not touch devices unless assigned QA ownership. Do not claim overall completion from your packet alone.

## 8. Review, commits and release gate

- Commit independently reviewable slices: transport; scheduler/scanner; opt-in API paging; store coverage; coordinator; incremental sync; worker seam/migrations; projections; QA evidence. Include each slice's tests with its implementation.
- Use focused tests during iteration; run full Flutter/API/auth/domain/console gates at the integrated checkpoint, then repeat only gates affected by subsequent changes. Preserve full logs outside staged source artifacts and redact sensitive evidence.
- Run analyzer and actual app/backend/console build commands relevant to this repository; verify each command completes. A skipped database test needs equivalent local Postgres/Linux CI evidence where required before release.
- Before committing inspect exact staged paths/diff and `git diff --check`. Before pushing fetch the named remote branch, inspect divergence, integrate with ordinary reviewed operations, rerun affected gates, then push normally. No force-push or detour through master is needed.
- User has authorized commits/pushes to `origin/codex/ios-shortcuts-prototype`; this is distinct from deployment. Inspect workflow triggers before pushing, because branch commits/workflow markers may cause deployment. Do not add deployment markers as part of a performance packet.
- Final acceptance requires current signed-in emulator evidence, physical confirmation for the reported real-device lag, complete relevant tests/builds, financial-integrity review and explicit accounting for every unresolved failure. Signing credentials or an unavailable authentication handoff can block release/device proof while independent implementation proceeds.
- Roll back a failed slice with a focused reviewed revert that preserves financial data and existing migrations; do not reset the checkout or wipe app data. Worker/schema changes need backward-compatible recovery before rollout.

The lead may mark the seven original items complete only when their implementation and acceptance evidence are both present. Do not promise “no lag in every possible scenario”; enumerate the tested scenarios, dataset and device limits precisely.
