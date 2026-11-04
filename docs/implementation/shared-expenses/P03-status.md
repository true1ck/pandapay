# P03 handoff: authenticated command boundary and bounded read adapters

Updated 4 November 2026. Writer `/root/split_command_api`. Baseline `sms-v2/integration` @ `2608053b`, with concurrent root/P01/P04/P05 work preserved. Packet **implementing**; this API sub-increment is implemented and focused-tested. It does not complete source-funded acceptance, report integration, recovery, capacity or end-to-end UI/device gates.

## Owned files and integration seam

- `api/src/shared_expenses/canonical.js`: restricted canonical JSON and SHA256 of the entire immutable envelope, including operation ID. UTF-8 byte limit 65,536, depth 16, 8,192 nodes, array length 1,000, 128 ASCII identifier keys/object and 128 characters/key. Only JSON scalars and safe integer numbers; exact financial values remain strings. Rejects malformed surrogate pairs, sparse/non-JSON collections, prototype hooks, object/array accessors, cycles and unsupported types before hashing. No private input appears in errors.
- `commands.js`: closed version-one command validation and fixed, parameterized SQL function dispatch. Uses existing pure `projectExpense` to validate balanced snapshots, canonical UUIDs for stored identities, date validation, positive bounded integer-string settlements, per-payer source budget checks and typed references. Does not authorize source ownership/valuation by parsing alone.
- `queries.js`: scoped keyset read repositories, current projections and materialized record-level change feed. Never selects private source links or settlement references. Explicit named revision columns use P01 column ACLs; all financial reads require active context authorization.
- `routes.js`: `registerSharedExpenseRoutes(app,{requireAuth,withUserClient})`. Root owns the `api/src/index.js` require/registration and actual production auth/database configuration; this worker changed neither.
- Focused test files `api/test/shared_expenses_{canonical,commands,queries,routes}.test.js`.
- Shared `contracts/shared_expenses/v1/command_vectors.json`: four independent Python JSON/SHA256 expected-value fixtures consumed by Node and the P05 Dart adapter, including Unicode and ordered exact amounts.

## Implemented request/response contract

`POST /shared-expenses/commands` accepts only `{schemaVersion:1,operationId,kind,payload}`. Actor identity comes from the existing authenticated request, never a body field. Supported kinds: `context.create`, `member.invite`, `membership.respond`, `expense.propose`, `expense.respond`, `settlement.report`, `settlement.respond`.

Dispatch is limited to named P01 functions: `create_context`, `invite_member`, `respond_membership`, `submit_proposal`, `respond_expense`, `report_settlement`, `respond_settlement`. No table CRUD, arbitrary function names or arbitrary journal-delta write endpoint. The server derives the request hash and the database enforces durable actor-scoped receipts/current authorization/revision preconditions. A UPI callback is not a confirmation command.

Command success and `GET /shared-expenses/operations/:operationId` return:

```json
{"receipt":{"operationId":"uuid","kind":"context.create","requestHash":"sha256","contextId":"uuid","result":{},"state":"committed"},"records":[]}
```

The empty records array does not fabricate acceptance or mean that the account has no shared records. Authoritative projection updates come through the change feed. Operation lookup is scoped to the authenticated actor and reauthorizes the current context before disclosing the stored result.

Read routes: capabilities, context list/detail, context members/expense heads/balances/activity/settlements, expense detail/revision pages and operation lookup. Page requests use `limit` (default 50, maximum 100) and opaque `after` (maximum 1,024 characters). Lists return `{items,nextCursor,hasMore}`. Context list/detail include `membershipState` so an invitation remains distinct from accepted membership. Financial child reads require active membership. Context cursors preserve all six PostgreSQL timestamp fractional digits rather than round-tripping through JavaScript millisecond dates.

`POST /shared-expenses/sources/inspect` accepts closed identity-only data and restricts discovery to its authenticated owner. `.../sources/admit` requires the exact server fingerprint and existing typed reference; it does not reserve or fund an accepted source-linked expense. P01 keeps `sourceFunding:false` until source writer guards/remapping/correction integration is complete.

All successful/error route responses after authentication are `Cache-Control: private, no-store`. Capability discovery uses a savepoint: only a genuinely absent schema/table/function becomes explicit unavailable capability data, and the outer user transaction is restored after that failed lookup. Other errors retain safe HTTP semantics; raw SQL, identifiers, contact information and private exception bodies are never returned. Disabled financial reads return an actionable 503, never a fake empty report.

## Materialized change feed and cursor safety

`GET /shared-expenses/changes?limit=100&after=<opaque>` returns exactly:

```json
{"records":[],"nextCursor":null,"hasMore":false,"revokedContextIds":[],"grantedContextIds":[]}
```

Each record is `{entity,id,contextId,revision,payload,deleted}`. Revision is an exact decimal string. Supported feed entities currently include contexts, members, expense heads/authorized origin revisions, pair balances, own personal-cost facts and authorized activity. A head has `recordType:head`; an immutable revision uses `recordType:revision` and a composite expense/revision ID. No bank transaction or reward record is synthesized.

The cursor is bound to actor and feed kind and tracks **profile sequence plus materialized record key**, not only the raw profile-event sequence. A source event can therefore span several pages without losing its remaining records. SQL uses a maximum ten-event window, native UUID keysets and per-branch limit before JSON shaping; ordinary financial changes read only their indexed journal origin pair keys. P01 added `shared_journal_origin(context_id,origin_id,low_member_id,high_member_id)` for that bounded lookup. Full context grants enumerate current accepted heads, members, active pairs and own cost facts with the same paging limits.

Returned records are capped at 100, individual records at 262,144 bytes and page records at 1,900,000 UTF-8 bytes (leaving transport-envelope headroom under the P05 2 MiB cap). On byte cutoff, cursor advances only through actually returned records and `hasMore` stays true. A terminal grant marker follows its snapshot rows; `grantedContextIds` is emitted only when that marker is consumed. P05 quarantines records under a durable revocation fence until the terminal grant. Current RLS access is rechecked by every SQL page. Revoked scopes produce an explicit tombstone and revocation list; revocation wins over grant within one page.

## Test evidence and independent checks

- RED: all four focused suites failed on missing modules/functions before implementation. Later focused red cases reproduced microsecond cursor loss, absent source detail functions, missing array-accessor rejection, invalid control-character names and failure to recover the capability savepoint.
- Final focused sub-increment: **34 tests passed**, zero failures. Includes actual loopback HTTP requests using a synthetic injected auth middleware, unknown/missing capability handling, closed validation, idempotent wire/hash expectations, private error suppression, pagination scope, byte-cut cursor preservation and revocation markers. These HTTP tests are not JWT/provider/device authentication evidence.
- P01 independently ran the repositories against the disposable PostgreSQL fixture under actual `app_user` and column/RLS constraints. The first materialized-feed execution caught PostgreSQL `42P18` for an untyped bind placeholder; fixed with an explicit type, then the actual recursive limit-seven feed passed to completion across all six materialized entities and terminal grant. The combined P01 test run reported **48/48**, zero skips. Root owns final pinned integration/full-chain database evidence.
- An intermediate full API `npm test` had **1,495 passed, one failed, nine skipped**: the only failure was the concurrently added `shared_expenses.settlement_private_references` missing root-owned portable backup coverage classification. No passing full-suite result was claimed from that run. Final full API rerun: **1,497 passed, nine skipped, zero failed** (`npm test`, including the repository syntax checks). Skipped database suites are not a claim of real DB coverage; the separate P01 fixture provides its specific DB evidence.

## Remaining packet/release gates

Root reporting integration, 4 November: added exact `/overview`, context `/totals`, personal `/activity`, direct/group context filters and bounded search. Cursors are bound to their query/filter scope. Screen totals read current accepted materialized totals and pair balances, never the sum of a loaded page. Expense rows expose current actor paid/share values separately; pending proposals do not acquire fabricated accepted amounts. Direct-context listing is not yet cross-group friend aggregation.

Latest full API regression after these additions: **1,501 passed, nine skipped, zero failed**, including syntax checks. Log: `.flutter-direct-appdata3/shared-api-regression.log`. The separate root/P01 real PostgreSQL suite verifies the implemented SQL flows; skipped API suites remain skipped, not silently counted as covered. No deployment, source funding activation or provider-verified UPI claim.

1. Existing-source/card-funded UI intents must keep their typed source reference; never strip it or turn a pending source link into an unlinked accepted claim merely because source funding is disabled. That would allow consumption to be counted twice. Explicit new unlinked cash/friend-paid entry remains its own reviewed user intent.
2. Root integration must pin and run the combined API/P01/P05 implementation, real authentication/ACL/role setup replay, stale cursor/account-switch tests and representative load/fault scenarios. Isolated tests do not establish a released feature.
3. Source-linked funding remains intentionally unavailable until every relevant legacy/v2/foreign writer participates in reviewed version/reservation/retraction guards. Legacy purchase classification needs explicit current-source confirmation rather than `entry_kind=spend` inference.
4. Regrant snapshot covers current accepted heads/balances and own cost facts. Complete pending-claim discovery/history hydration is still an explicit P07/P05 gate through authorized revision/history pages; do not label a partial historical cache complete. Full grant paging must be reconciled with writes occurring during hydration and concurrent membership changes under the final integration protocol.
5. Every future revocation writer must emit a committed notice to the removed actor's profile stream. RLS denial of a read does not by itself guarantee that an inactive device learns of a revocation for an older cached context. Lifecycle/recovery/portable coverage and reset policies remain root-owned release gates.
6. Global friend aggregation/search, current report/totals projections, all C01–C22 behavior, provider-verified settlement/reversal and notification/link flows require their remaining packets. No fabricated `totals` record or cross-context netting is emitted by this API increment.
7. Million-user capacity, query plans at representative history sizes, source cutover, device UI and production deployment are unverified. No commits, stage changes, push, migration against an ambient database or device/auth operations were performed by this worker.

P05 client compatibility review: server context denial uses `404/context_not_found`; the client must purge/fence that requested cached context in addition to `403/context_not_authorized`, while keeping an expense-only 404 separate. This concrete mismatch was reported to the P05 writer/root for its owned fix. No client file was edited by this writer.
