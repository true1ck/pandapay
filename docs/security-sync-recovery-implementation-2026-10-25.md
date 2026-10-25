# Sync, recovery validation and audit provenance — 25 October 2026

This P03/P04/P06/P11 slice validates sync requests, checks recovery scope metadata before restore writes, and adds optional history references for private secret-review work. Three Luna agents implemented disjoint files; the coordinator integrated and reviewed the result. **All 22 scoped findings remain unfinished: 19 partial, three open.** No live database, key, migration, provider, deployment or feature activation was performed.

## Implemented behavior

| Area | Change | Compatibility and boundary |
| --- | --- | --- |
| Sync transport | Validate UUIDs, object/list shapes, safe integer sequences/clocks and cursor/ack inputs before SQL. Keep the 200-item push bound and effective pull-limit clamp. | Existing Dart callers, optional registration fields, unknown/stale device recovery, platform fallback and successful response shapes remain. Negative safe pull cursors still replay from the beginning. Unknown entities remain SQL-owned policy. |
| Sync failures | Return fixed SQLSTATE-based per-item details and a generic fallback instead of raw database error text. The existing split-total warning requires an explicit internal error code. | Ordered per-item savepoints, partial push success, result keys and conflict policy remain. A rejected item rolls back while later valid items proceed. No clock-ordering or shared authorization redesign. |
| Recovery restore | Require boolean `include_receipts` and `include_unsynced: true` before filesystem or SQLite work. | Current v1 capture already emits these fields. Valid older v1 snapshots remain restorable when the destination has added a new scoped table. Existing IDs, queued mutations, receipt semantics and OTP/no-new-password flow remain. |
| History review | Opt-in `--history-full-retained --history-provenance` adds bounded finding-to-blob and containing-commit references, without values or context. | Default output is unchanged. `observed_commit_id` identifies a containing commit encountered during traversal; it is not an introduction date. The sidecar stops at 5,000 records/2 MiB and reports truncation as incomplete. |

Sources: [sync validators](../api/src/sync_request_validation.js), [route integration](../api/src/index.js), [snapshot restore](../app/lib/data/portable_backup/account_recovery_local_snapshot.dart), [audit tool](../db/scripts/release_secret_audit.js).

Recovery scope validation does **not** establish complete snapshot coverage. A v1 archive has no producer-schema manifest that distinguishes an omitted source table from a table added only in the newer destination. Requiring every destination table would reject valid older copies. A compatible authenticated manifest/coverage design and integrated fresh-phone receipt/queue parity remain P06 work. Normal app database and receipt storage still require encrypted startup/writer/consumer integration; these checks do not enable that transition.

## Verification

[Exact-source evidence](../artifacts/security-sync-recovery-2026-10-25/verification.json) records the candidate hashes, test results and preservation checks. Counts overlap.

| Check | Result / scope |
| --- | --- |
| Full API | 1,004 passed, two existing database-dependent skips; 1,006 total |
| Database tools | 193 passed |
| Full Flutter app | 1,631 passed; analysis exited successfully with 80 information-level lint messages, zero warnings/errors |
| Focused recovery | 30 passed, including inconsistent scope rejection before writes and legacy snapshot restore with a newer destination table |
| Node 22 container | 16 sync validator/actual-route tests passed with no network and read-only sanitized source |
| PostgreSQL 18 | Fresh and repeated checksummed full-schema migrations passed. Route/RLS checks passed for registration, ordered note updates, rejection rollback, cross-account refusal, device filtering and monotonic acknowledgement. Existing numeric writes still reject with `42804`; remedy pending. |
| Retained history | Final frozen-source pass completed 651 retained commits / 4,235 recognized-text blobs (128,093,276 bytes); all 32 historical heuristic flags have bounded provenance records. 52 flags total; no values emitted. Classification/native/excluded-path review remains. |

The initial history attempt completed its text traversal but its overall result was incomplete because source changed during the scan. The final pass matches the recorded candidate hash and has no scope/budget/provenance truncation. This is point-in-time retained-ref release-source text coverage, not all repository paths or a clean-release conclusion.

The PostgreSQL harness seeds only synthetic accounts/devices/transactions on an owned clean loopback database and rolls its data back. It exercises actual route fragments and database routines under `app_user`, without starting providers, workers or loading private configuration. VM route tests separately prove malformed requests make no SQL call. These checks do not replace a deployed HTTP/proxy/client or intended-provider acceptance run.

The current batch changes four existing release-source files and adds five files; all other baseline release-source hashes are preserved, including original notification edits, auth/key readers, locks, schemas, migrations, deployment configuration and feature defaults. The earlier original-key protected restore remains dated evidence; no fresh private backup or live read was needed for this batch.

## Confirmed existing sync SQL issue

The fresh PostgreSQL 18 fixture confirmed that positive and negative `amount_inr` updates are both rejected with SQLSTATE `42804`: the existing `0034_sync_engine.sql` assigns a text expression to numeric columns. A note-only update succeeds. This is an unresolved existing route/SQL contract gap, not a successful numeric-write test. The final harness records that rejection and unchanged amount explicitly, alongside valid note updates, per-item rollback and later success. No numeric-write remedy is claimed.

Do not fix this by changing casts alone. The existing sync RPC updates fields directly; enabling financial-field writes requires reviewing transaction-state/reward recomputation, split limits, clocks, duplicate/retry and cross-account behavior together. `0035_sync_status_field_fix.sql` already documents why raw status updates were removed. Prepare a new compatible migration and route integration, leaving historical checksums intact; rehearse complete before/after financial state and replay before enabling changed behavior. Extend this review to the other allowed UUID/boolean/date/enum/numeric fields. This remains within M4/P04 and the financial reproducibility scope, without adding a newly closed finding.

## What remains and the next slices

1. P06: design a backward-compatible authenticated producer-schema/coverage manifest, then prove complete receipt/queue/deferred-SMS recovery and consent/deletion races within measured free-host quotas. Preserve valid v1 readers; do not silently omit data to fit.
2. P04: first repair the confirmed typed-field SQL/financial-side-effect contract with a separate migration and complete accounting tests; then extend one route/entity family at a time with explicit ownership, types, numeric bounds and mixed-batch semantics. Finish the broader capability/abuse matrix separately; sync transport checks alone do not close M3/M4/N02.
3. P03: privately classify each historical flag using its observed commit/blob, inspect excluded paths and exact native/release artifacts, and finish dependency/license/advisory applicability. Locations are review leads, not confirmed exposures or a clean-release certificate.
4. P01/P02: reconcile historical financial IDs/state and measure concrete index retain/remove decisions on the exact protected clone before mutations. Zero current duplicates cannot prove historical preservation.
5. P07/P08/P09/P10: complete encrypted normal startup, all writers and receipt consumers, then signed-device, intended-PostgreSQL-provider, independent custody and monitored rollout acceptance. Original keys and disabled defaults stay in place meanwhile.

[Plan](security-data-dependency-mobile-documentation-plan-2026-10-25.md) · [Per-finding gaps](security-focused-gap-review-2026-10-25.md) · [Previous retained-reader batch](security-key-readers-implementation-2026-10-25.md)
