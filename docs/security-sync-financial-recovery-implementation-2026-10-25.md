# Typed sync and recovery coverage — 25 October 2026

The next P04/P06/P11 source batch prepares a typed sync writer with financial-state reconciliation and adds recovery coverage metadata. Three Luna agents implemented separate files and reviewed the integration; the coordinator handled configuration, route wiring and local verification. **22 scoped findings remain unfinished (19 partial, three open).** Typed writes and normal mobile encryption remain disabled. No live database, key, contact, provider or deployment change occurred.

## Implemented behavior

| Area | Result | Compatibility / boundary |
| --- | --- | --- |
| Typed sync SQL | Additive `sync_apply_change_v2` converts only winning allowlisted fields through the actual PostgreSQL row type. It locks the owned row, preserves field clocks/conflict records, rejects fractional paise and invalid limits, checks authenticated profile/device and related-card ownership, restricts execution and pins the search path. | Original RPC, grants and historical migration bytes remain unchanged. Specialized category/rule RPCs retain their own behavior. Current field clocks are still based on device time. |
| Financial edits | The API locks/snapshots the transaction, invokes V2, compares accepted stored inputs, validates active/card/split rules, then uses the existing reversal/application core inside the item savepoint. Nested owned private categories resolve their public ancestor for reward calculations. | Stale fields, note-only writes and same-value retries leave financial state unchanged. Failure rolls the whole item back while later valid items continue. Existing backfill/suppression rules remain. No new independent financial formula. |
| Status/delete protection | Generic transaction sync rejects status changes and deletes before either writer branch. | Current Dart sync callers do not enqueue these operations. Existing status/ignore domain routes remain the supported path. Older-client acceptance still belongs to the release gates. |
| Activation | `SYNC_TYPED_WRITES_ENABLED=false` in runtime/templates/Compose; only exact `true` selects V2. Release checks require explicit manifest/runtime parity and a bound `sync_typed_writes_acceptance` proof. | Old release-input manifests may omit the new flag while off. There is no automatic activation or fallback from a failing enabled V2 writer. |
| Recovery coverage | New v1 snapshots add optional versioned coverage inside the existing authenticated encrypted payload: schema-derived tables/columns, independent source counts, row digests and receipt counts/digests. Restore checks declared coverage and receipt ownership/bytes before filesystem or SQLite writes. | Existing v1 copies without coverage remain accepted; newer destination tables/columns are allowed. Original IDs, queues, OTP, receipt opt-in and no-extra-password flow remain. No cipher or outer archive format change. |

Sources: [migration](../db/supabase/migrations/20261025150000_sync_apply_change_v2.sql), [transaction applier](../api/src/sync_transaction_state.js), [API integration](../api/src/index.js), [snapshot coverage](../app/lib/data/portable_backup/account_recovery_local_snapshot.dart), [release guard](../db/scripts/release_security_check.js), [rollout notes](../deploy/DEPLOY.md).

The previous `42804` numeric failure is repaired in the **opt-in V2 path**. The default legacy writer still rejects numeric updates; the source change is not a production fix or activation. Current-client instrument/entry-kind fields are supported by V2 instead of being silently omitted there. Transaction status is excluded from V2 even though later historical allowlist overrides restored it in the legacy RPC.

Private-category resolution changes the category used for financial computation, while preserving the stored payload/public-category value and field clocks. The ordinary PATCH path still needs its own nested-category/persistence parity review. The shared state core also retains its documented approximation when rules or reward-value cap context change since original application; historical reproducibility is not solved by this batch.

## Verification

[Exact-source evidence](../artifacts/security-sync-financial-recovery-2026-10-25/verification.json) binds the implementation, test scopes and preserved baseline files. Counts overlap.

| Check | Result |
| --- | --- |
| Full API | 1,024 passed; two existing database-dependent skips (1,026 total) |
| Database tools | 195 passed, including default-off, manifest compatibility and enabled-feature proof tests |
| Full Flutter app | 1,634 passed; zero analyzer errors/warnings and 80 information-level lints |
| Node 22 | 36 sync/configuration tests passed in a cached container with no network and read-only sanitized source |
| Compose / syntax | Production and staging parse with private environment resolution disabled; the new flag defaults off. API syntax checks passed. |
| Retained text review | Frozen-source scan completed 655 retained commits / 4,246 recognized-text blobs; all 32 historical flags have provenance. 52 heuristic flags total, no values emitted. Classification and excluded/native artifacts remain. |
| Fresh PostgreSQL 18 | Full product migration and checksummed repeat passed. V2 typing/constraint/role/ownership/clock tests passed; low-privilege execution is denied, and the original function definition/grants remain unchanged. |
| Actual financial core on synthetic PostgreSQL | Amount edits reconcile caps, milestones, fee-waiver totals, expected rewards and the transaction-keyed points ledger. Same-value/stale updates, invalid-plus-valid items, split rollback, foreign ownership, nested categories, inactive/status/delete guards and cash transitions passed through actual route fragments and core functions. |
| PostgreSQL dump/restore | Complete synthetic schema dump restored on the same major. Profile/device/transaction/change-log data and V2 definition fingerprints match; typed writes reopen successfully afterward. |

The fixtures require explicit loopback test URLs, refuse existing account data and roll back seeded test work. A separate committed synthetic cash probe supplies the dump/restore parity test. The owned temporary cluster is stopped and removed. No real account, backup or private-key read was needed. The first full API attempt could not bind sandbox loopback listeners; the authorized local retry passed. Fixture-only enum, SQL-call and safe-message assumptions were corrected before final results.

The release-source baseline has 1,318 files. This batch intentionally changes 15 and adds six; the other 1,303 hashes remain unchanged. Original encryption/HMAC keys, auth source, dependency locks, historical migrations, unrelated notification edits and existing feature defaults are preserved. The new migration creates a function and grants; it rewrites no existing rows. The prior actual original-key restore remains dated evidence, not a rehearsal of this exact pending migration on current customer data.

## Coverage and rollout limits

Recovery coverage proves the current producer's declared eligible namespace-scoped tables and explicitly selected receipts. It cannot prove unknown external writers/stores, require coverage in legacy copies, recover work never uploaded, or replace complete fresh-phone/device-loss testing. Existing 5 MiB/two-copy limits, consent, foreground/online cadence, backoff and local backup storage limits remain. Normal SQLite/receipt encryption is still separate unfinished work.

Typed SQL, sequential financial tests and a same-major local dump/restore do not establish concurrency across different financial transactions, historical rule fidelity, all current/oldest-client combinations, signed devices, provider privileges, a PostgreSQL 17 target, independent custody or production acceptance. Keep the switch off until the exact current protected clone, target provider and required acceptance matrix pass. Schema must precede API activation. Preserve committed writes/history for forward repair; selecting the old numeric-rejecting writer is not an undo procedure.

The implementation uses [PostgreSQL row-type JSON conversion](https://www.postgresql.org/docs/17/functions-json.html) and restricted function ownership/execution consistent with [Supabase function guidance](https://supabase.com/docs/guides/database/functions). The current [minor-upgrade notice](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes) remains relevant to the separate target-provider extension/operator/decryption review; no provider upgrade was performed.

## Next bounded work

1. Rehearse typed writes on the complete current protected clone and PostgreSQL 17/intended provider; add simultaneous edits, period/cap boundaries, rule changes, full supported-client and restart/outage cases before activation proof.
2. Complete recovery fresh-install receipt/queue/deferred-SMS parity, consent-disable/upload and deletion races, measured sizes and recovery-point acceptance. Preserve legacy archive readers and explicit opt-in.
3. Integrate encrypted normal startup, all writers and receipt consumers only after recovery eligibility is accepted; keep signed-device/crash/key-loss checks ahead of activation.
4. Continue historical ID/state reconciliation and measured index decisions, release artifact/dependency review and independent backup/journal custody. These remain separate open/partial findings.

[Updated implementation plan](security-data-dependency-mobile-documentation-plan-2026-10-25.md) · [Per-finding gaps](security-focused-gap-review-2026-10-25.md) · [Previous sync/recovery batch](security-sync-recovery-implementation-2026-10-25.md)
