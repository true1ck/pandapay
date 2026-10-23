# Portable backup implementation status

Status reviewed 23 October 2026. This document tracks the portable, user-account export work. It does not describe or replace the separate paired PostgreSQL disaster-recovery backups.

## Current status

The merged implementation provides server export/restore services, a concrete SQLite snapshot source, streamed HTTP consumption and local restore writers. The authenticated `/portable-backups/export-v1` route streams selected product-database sections as NDJSON. The API does not create an encrypted archive by itself. The service layer and local restore components do not constitute completed device acceptance or UI integration.

The portable backup feature is incomplete:

- `local_snapshot_source.dart` now implements the existing snapshot interface against SQLite, including active/legacy namespaces and pending-outbox checks. The API export alone still contains server rows; the full local-data scope requires its own device acceptance.
- HTTP and local snapshot/restore services are present, but the one-call feature driver and approved UI integration remain open.
- Restore session routes and a local end-to-end restore fixture are present. Actual PostgreSQL migration/RLS execution and the device A/B drill remain acceptance gates.
- User-linked referral and credit data in the `promotions` schema is explicitly excluded from this export and remains a recovery gap.
- Cross-runtime encryption vectors and device compatibility/large-account acceptance remain open.

The archive's passphrase encryption work, where used by the separate portable archive format, is not the user's account-recovery method. It does not replace or complete the existing phone/email OTP recovery, and no additional recovery-password prompt is part of the approved recovery path.

## PostgreSQL migration-table inventory

`api/src/portable_backup/coverage.json` classifies **143 persistent PostgreSQL tables** declared in the 97 `db/supabase/migrations/*.sql` files:

| Disposition | Count | Meaning |
| --- | ---: | --- |
| `exported_v1` | 27 | Included in the account-scoped server export |
| `global_catalog` | 32 | Shared catalog/configuration, not exported per account |
| `platform_ops` | 45 | Platform, worker, telemetry, or operational state |
| `excluded_with_intent` | 39 | Explicitly omitted; reasons identify scope gaps and recovery implications |

Public-schema keys remain unqualified for compatibility. Non-public schema keys are fully qualified, so `promotions` tables cannot be confused with public tables. Migration-only temporary tables are excluded from this persistent-schema count. The coverage test strips SQL comments and string literals before scanning, and includes a fixture for same-named tables in `public` and `promotions`.

This registry covers server migration tables only. It does **not** inventory SQLite tables, individual columns, or all user state, and it is not a full database disaster-recovery manifest. The separate paired PostgreSQL backup/restore path is responsible for database disaster recovery.

## Implemented pieces

- `api/src/portable_backup/contract.js` defines the static section allow-list and canonicalization rules.
- `api/src/portable_backup/export.js` streams profile-filtered sections in batches and emits counts/digests in a completion footer.
- `api/src/portable_backup/routes.js` mounts the authenticated, repeatable-read, read-only export transaction.
- Security integration corrected first-page bind parameters and settings pagination. Exports now have a 10-minute deadline, 30-second stalled-response bound, 64 MiB total NDJSON cap and one-million-record cap. Each API process admits one export at a time; excess requests receive `503 export_busy`. These are per-process limits, not a distributed budget. Limit failures abort without a successful completion footer. The paired PostgreSQL backups are separate and do not use these account-export limits.
- The app has portable archive/encryption, attachment collection, a concrete SQLite snapshot source, HTTP export/restore consumption and transactional local restore/finalization components. UI/feature integration and device acceptance remain separate gates.
- `api/src/portable_backup/coverage.json` records all 143 persistent migration tables and explicitly records the referral/credit export gap.

## Historical verification from the dev review

| Command | Result |
| --- | --- |
| `cd api; node --test test/portable_backup_coverage.test.js` | 4 tests passed, including schema collision and SQL comment/string regression fixtures |

These are historical results from before this merge. Passing the coverage test verifies the migration-table classification inventory; it does not prove completeness of local app data or a working restore. No tests were run as part of the merge.


The following implementation notes and results were carried in from master; they were not rerun during this merge.

## Follow-up evidence reported in master (23 October 2026)

- Server restore protocol is mounted at `/portable-backups/restore-sessions` and supports idempotent session creation, section upload, preview, guarded commit, status and cancellation.
- Restore validation now accepts the frozen Dart manifest shape (`account_binding`, `schema_version: portable-v1`, array sections with `record_count` and `byte_length`).
- Local snapshot capture includes active and legacy namespaces, orders composite tag links deterministically, and refuses pending outboxes.
- Existing `DataExportScreen` and `DataTransferScreen` were restored unchanged after the user requested that no UI be changed. The new export/restore services remain behind existing data-transfer integration points.
- `api`: `node --test test/portable_backup_export.test.js test/portable_backup_restore.test.js test/portable_backup_coverage.test.js test/csv.test.js` — 28 passed, 0 failed.
- `api`: `npm run check` plus explicit restore syntax checks — passed.
- `app`: `flutter analyze --no-pub lib/data/portable_backup test/data/portable_backup` — no issues.
- `app`: portable backup directory plus explicit restore/snapshot/HTTP-consumer tests — 51 passed, 0 failed.
- `app`: `flutter build apk --debug --flavor dev --no-pub` — passed; full multi-flavor build was not attempted after a disk-space failure.

## Remaining gaps (recorded, not blocking the verified service layer)

1. ~~`PortableLocalSnapshotSource` has no concrete drift-database implementation yet~~ **Done**: `app/lib/data/portable_backup/local_snapshot_source.dart` implements it against the raw-sqlite3 `AppDatabase` (the project local store is `package:sqlite3`, not drift). It reads all sections in one deferred transaction, captures active plus `legacy` namespaces, decodes embedded JSON columns so section digests stay stable, counts the nine outbox queues (absent table = 0 pending) and refuses nonzero pending counts; per-queue drain hooks plug into existing flush machinery without bypassing outbox semantics. `flutter test test/data/portable_backup` green (46 tests), `flutter analyze lib/data/portable_backup` clean.
2. Not a single device benchmark exists for Argon2id v1 params (16384 KiB mobile budget); on-device runtime remains an acceptance item.
3. Cross-runtime encryption test vectors (Android/iOS/JS) not yet generated.
4. Offline restore loop is now complete locally: `local_restore_writer.dart` provides `LocalPortableRestoreWriter` (single SQLite transaction, namespace wipe + replay of every portable section with `match_terms_json`/`payload` re-encoded, projection rebuild mirrors `FinancialStore._upsert` including `_num` null-to-0 rupee semantics, attachment install by manifest id) plus `LocalPortableRestoreTargetInspector` (fresh-namespace gate over raw tables, absent table = 0 rows). The end-to-end chain source capture -> real Argon2id archive -> `inspectAndStage` -> finalize -> recapture is byte-identical per section and covered by `app/test/data/portable_backup/portable_restore_local_e2e_test.dart` and `local_restore_writer_test.dart` (55 Dart portable tests total, analyzer clean). Still open within this gap: a one-call driver (`PortableBackupHttpRepository` restore endpoints already exist) that the UI/feature layer can call once the UI is unlocked; UI remains intentionally unchanged per the user's direction.
5. Golden fixture: `app/test/fixtures/portable_backup_fixture.dart` covers inspector shapes; a full end-to-end archive binary fixture suitable for all three inspectors is still open.

Agents must append exact commands, counts, failures and unresolved risks here when reporting. This file must not claim completion from mocked or skipped database/device gates.
