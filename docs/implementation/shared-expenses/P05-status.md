# P05 handoff: immutable local commands, projections and authenticated transport

Updated 4 November 2026. Writer `/root/split_ui_shell`; assigned after P04 shell handoff. Baseline `sms-v2/integration` @ `2608053b`; shared internal wire/fixture version `1.0.0-foundation`. Packet **implementing**; isolated storage/sync/authenticated-HTTP sub-increment **ready for integration review**. Final focused suite: **44 passed**, zero failures; scoped analyzer clean. Root owns existing-provider/recovery/UI integration. No packet-level end-to-end/device/production claim.

## Owned source and API

- `app/lib/features/shared_expenses/storage/shared_schema.dart`: additive module tables and own `shared_schema_version`; version 2 adds context/overview keyset indexes over version 1. Uses the existing AppDatabase handle, leaves PRAGMA user_version and legacy rows intact.
- `shared_store.dart`: namespace-bound immutable operation queue, source/operation dependencies, provisional author overlays, unique durable per-acquisition leases, atomic receipts/projections/overlay cleanup, conflict/auth/backoff states, bounded keyset projection/context/pending queries, cursor+page atomicity and access-revocation fences.
- `app/lib/features/shared_expenses/data/shared_commands.dart`: restricted canonical JSON, SHA256 of the full `{schemaVersion,operationId,kind,payload}` envelope, detached command/receipt/projection/page models. Seven root-approved kinds: context.create, member.invite, membership.respond, expense.propose, expense.respond, settlement.report, settlement.respond.
- `shared_transport.dart`: typed injected remote interface; lookup/execute/one bounded pull, opaque committed receipt plus materialized projections. This is not a second API/financial truth.
- `shared_http_transport.dart`: actual existing AuthenticatedHttpClient injection, account-subject fencing, immutable bytes, disabled redirects, bounded streaming responses, strict materialized record DTOs and sanitized errors. Root owns HTTP-client/provider integration and any existing global transport changes.
- `app/lib/features/shared_expenses/sync/shared_sync.dart`: bounded worker with lookup-before-execute, original operation IDs on retry, account-generation fencing and recovery admission through asynchronous requests and durable acknowledgment.
- Tests under `app/test/features/shared_expenses/{storage,sync,data}/`; no new dependencies, manifests, lockfiles or global files written by this agent.

### Root-facing methods

`SharedExpensesSchema.ensure(Database,{allowNewerVersion:false}) → bool`, `.version`, `.tableNames`. Compatible/newly ensured returns true. Only a known future module version may return false when the core explicitly requests passive compatibility; shared feature writers remain strict. Unknown future metadata is not rewritten and no schema DDL runs on that path. Corrupt metadata/SQLite errors still propagate.

`SharedExpensesStore(AppDatabase, namespace:, recoveryGate?, isCurrent?, onChanged?)`:

- `enqueue(command, {dependsOn,sourceDependencies,provisional,createdAt})`.
- `operation(id)`, `pendingCount`, `provisional(id)`, `receipt(id)`.
- `claim(now:,leaseId:,leaseDurationMs:)`, `complete(claim,receipt,records)`, `fail(claim,statusCode:,now:)`.
- `resumeAuthentication()`, `resolveSourceDependency(key)`; neither mutates original wire payloads.
- `applyPage(page,expectedCursor:)`, `cursor`, `isContextRevoked(contextId)`, `revokeContext(contextId)` for an independently authenticated read denial without advancing the change cursor.
- `readPage(entity:,contextId:,afterId?,limit<=100)`, `readContexts(afterId?,limit<=100)`, `readPendingOperations(contextId?,afterId?,limit<=100)`. Pending results include detached provisional overlays with one SQL join, avoiding per-row remote fetches.

`SharedExpensesSync(store:,remote:,isCurrent:,now:,leaseId:)`: `flush(maxCommands<=100)` and one-page `pull()`. Root supplies scheduling/connectivity/capability and current-account generation; lease labels may be reused, acquisition tokens cannot.

`SharedExpensesHttpTransport(apiBaseUrl:,namespace:,client:AuthenticatedHttpClient,accessToken:,isCurrent:,onContextRevoked?)` uses `/shared-expenses/commands`, `/operations/:id`, `/changes?limit=...&after=...`. There is no unauthenticated default client. Root must not close the shared client through this adapter. Total responses stream under 2 MiB; each projection object is capped at 256 KiB, at most 100/page, cursor ≤1024 characters. PostgreSQL string sequence versions are checked before safe int conversion.

Read-only methods return validated JSON objects for the root's presentation adapters: `fetchCapabilities`, `fetchContexts`, `fetchContext`, `fetchMembers`, `fetchExpenses`, `fetchBalances`, `fetchActivity`, `fetchSettlements`, `fetchExpense`, `fetchExpenseRevisions`. List wrappers are closed `{items,nextCursor,hasMore}` with ≤requested limit ≤100; contextual rows must match the requested context ID. Paths are allowlisted methods, never caller-provided URLs. Known context denial invokes the scoped revocation callback; unrelated missing expenses do not purge a context.

## Financial and processing invariants

Commands are 64 KiB UTF8 maximum; ASCII object keys, depth ≤16, nodes ≤8192, arrays ≤1000, keys/object ≤128, safe integer scalars only, exact money strings and valid Unicode. Shared Node/Dart canonical vectors come from the common fixture with independently calculated Python JSON/hash expectations. Full envelope includes operation ID; changing a payload under that ID fails locally and an SQLite immutable-column trigger prevents accidental UPDATE.

Enqueue writes command/dependencies/private overlay together. Accepted commit writes receipt, approved projection and overlay removal in one savepoint. No await occurs inside a SQLite write transaction. A failed notification observer is reported with sanitized error code after commit and cannot turn durable success into a retryable failed enqueue.

Local leases prevent simultaneous send claims across connections and recover after process death. A late response cannot own a newer lease, even if workers reuse the same label. Lost responses look up the same operation before resending; source readiness is a scheduling dependency, never permission to replace IDs/hashes or synthesize canonical bank transactions. Financial commands never use legacy coalescing split_documents, SMS v2 outbox or cached_responses as their write truth.

409 revision conflicts stay blocked; an explicit server `retryable:true` serialization/deadlock conflict instead retries the same immutable operation. 401 waits for explicit same-account reauthentication; transient retry metadata stays durable. Server remains responsible for authenticated authorization, accepted whole revisions, source/reservation/version checks and effect uniqueness. Friend-paid data does not become a financial_entities bank transaction.

Accepted reads are indexed and bounded before JSON decoding. Pull records and opaque cursor commit atomically; stale revisions cannot overwrite newer ones, and equal-version/different-payload records fail. Receipt acknowledgments may precede the authoritative change feed; root UI must retain honest projection-lag/coverage state rather than fabricate accepted balances.

## Revocation and paginated regrant

The trusted account feed supplies explicit revokedContextIds and terminal grantedContextIds (each unique UUID list ≤100), distinct from archive/delete. Revocation purges cached accepted projections, stores a durable device tombstone and fences private reads, provisional overlays, receipt result access and queued writes. Authored immutable operations remain recoverable; a zero net, archive or source event never grants access.

Fresh server-authorized regrant records can span several bounded pages. They persist behind the tombstone and remain hidden across process death until the terminal grant marker clears it atomically. Renewed revocation purges partial cached rows again. Root/P03 own current authorization checks and terminal grant production; no per-event network lookup is used. Recovery clears device cursors/tombstones and must require fresh authorization before exposing restored cached shared scope.

## Root-owned integrations and recovery requirements

Root has now integrated the additive module schema into the existing AppDatabase open path, with passive handling of a future module version so the core app continues to open. Account recovery preserves immutable operation IDs/hash/bytes/dependencies/receipts and overlays, resets only delivery leases/retry scheduling, and excludes device cursors/tombstones from restored accepted scope. Portable queue coverage explicitly counts pending/conflicted shared work instead of claiming Backup complete. Accepted shared server history is classified as an explicit portable scope gap; it is not replayed as new money.

Completed root recovery/storage/sync integration run: **37 passed**, including future-version core preservation, capture/reopen/restore, command identity and existing lease/conflict/revocation cases. This is SQLite and recovery-fixture evidence. The server shared export contract and authorized server lifecycle remain open. Root runtime additionally uses the actual authenticated HTTP owner; the server's context-only `404/context_not_found` purges/fences cached scope while expense-only 404 retains group access.

Latest root analysis across all changed app/router/storage/recovery/shared/test paths: **no issues found**. The full Flutter run passed the new storage/recovery/HTTP cases and existing backup tests, but the entire suite was not green: 2,950 passed / four skipped / 16 failed. Twelve failures were reproduced as an existing Windows-only test fixture path issue and all 55 affected SMS replay/pipeline cases passed after the test-helper normalization. Four unchanged SMS screenshot-baseline failures remain explicit gaps. See the register for complete evidence; do not relabel the whole run passed.

1. Root owns AppDatabase.ensure placement before restore/provider construction; current connection only. Root owns existing providers/router/UI adapters and HTTP client refresh flags.
2. AccountRecoveryLocalSnapshot currently deletes scoped rows then plain INSERT, so immutable UPDATE triggers do not fire there. Other merge paths must compare existing identity/hash/bytes and skip equal immutable rows; never ON CONFLICT UPDATE their immutable columns.
3. Preserve operation IDs, request bytes/hash, dependencies, receipts and provisional overlays on account recovery. Reset only sending→retry, lease IDs/expiry and retry timing; retain conflict/rejected/auth states. Exclude/reset shared_sync_state device cursors/tombstones and require fresh account authorization before cached view.
4. Portable source has a fixed queue inventory: root must count/drain `shared_commands WHERE state!='committed'` explicitly and refuse a complete export if pending/conflicted work remains. New canonical shared sections/allowed restore schema and server backup coverage require explicit root/P01 changes.
5. Root's account-recovery integration test is `app/test/data/portable_backup/shared_expenses_recovery_test.dart`; that agent owns it. No child claim of passing that separate integration test until root runs it.

## Verification log

- Storage/sync tests were written first and failed on absent modules/functions. Then **14 passed** for file restart/isolation, immutable ID conflict, leases/dependencies, atomic acknowledgment, conflict/pull behavior and network faults.
- Extended **26 passed** with shared canonical hashes, malformed Unicode/depth/node bounds, SQLite immutability, observer failure, identical-worker-label stale lease, atomic mid-projection rollback, auth pause, bounded 100-row SQL pages and recovery admission.
- New bounded hub/pending methods and explicit revocation behavior each had an observed compile RED before implementation. HTTP tests likewise failed on missing adapter before creation.
- Final **44 focused tests passed**: 30 storage/canonical cases, three sync faults and 11 authenticated HTTP cases. File-backed native SQLite tests reopen files and exercise two connections; this is local storage evidence, not production PostgreSQL evidence. Scoped analyzer: **no issues**. Diff whitespace check clean.
- Added real version-one→two file upgrade preserving pending command bytes/overlay; future version 999 passive-core/strict-feature preservation; paginated regrant remaining hidden through process restart and renewed revoke; immutable retained receipt reconciliation after delivery-state reset. The receipt replay defect was observed as a UNIQUE-constraint RED before implementing exact retained-receipt comparison/reuse.
- Independent P03 client/server wire review found the server's RLS-safe `404/context_not_found` must fence cached scope as well as `403/context_not_authorized`. A failing callback regression reproduced that mismatch, then passed after correction. `404/expense_not_found` explicitly leaves context access intact. Existing authenticated-owner retry flags were already correct on source inspection; no global HTTP fix is claimed. A regression confirms no-redirect and immutable bytes on both pre/post-refresh attempts.
- No global DB/recovery/provider changes, deployed migration, device installation, auth automation, source cutover, Git stage or commit performed by this writer. Root's separate global recovery/combined app tests, native rendered-font/device flows, authenticated real server integration, independent storage/security review and load/fault acceptance remain required before marking P05 integrated/verified.

Run from app using the existing Flutter SDK and current locked dependencies:

```powershell
flutter test --no-pub --concurrency=1 test/features/shared_expenses/storage/shared_store_test.dart test/features/shared_expenses/sync/shared_sync_test.dart test/features/shared_expenses/data/shared_http_transport_test.dart
dart analyze lib/features/shared_expenses/storage lib/features/shared_expenses/data lib/features/shared_expenses/sync test/features/shared_expenses/storage test/features/shared_expenses/sync test/features/shared_expenses/data
```

This sandbox used the direct Dart SDK plus Flutter snapshot entrypoint with repository-local APPDATA/LOCALAPPDATA/PUB_CACHE and approved existing SDK cache access, as P04 records. Logs remain local under `.flutter-direct-appdata3/p05-focused-tests.log`.
