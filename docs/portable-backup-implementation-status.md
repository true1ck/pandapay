# Portable backup implementation status

Status reviewed 23 October 2026. This document tracks the portable, user-account export work. It does not describe or replace the separate paired PostgreSQL disaster-recovery backups.

## Current status

The implementation currently provides **server export primitives**, not a complete account backup or restore flow. The authenticated `/portable-backups/export-v1` route streams selected product-database sections as NDJSON. The API does not create an encrypted archive by itself.

The portable backup feature is incomplete:

- `PortableLocalSnapshotSource` is an interface; there is no adapter that captures the app's existing SQLite database. Local financial state, captured SMS and decisions, pending queues, and other local records are therefore not covered by the API export.
- There is no integrated client flow that joins the server stream, local snapshot, and attachments into a user backup.
- There is no restore API or end-to-end restore flow.
- User-linked referral and credit data in the `promotions` schema is explicitly excluded from this export and remains a recovery gap.
- Cross-runtime encryption vectors and device compatibility/large-account acceptance remain open.

The archive's passphrase encryption work, where used by the separate portable archive format, is not the user's account-recovery method. It does not replace or complete the existing phone/email OTP recovery, and no additional recovery-password prompt is part of the approved recovery path.

## PostgreSQL migration-table inventory

`api/src/portable_backup/coverage.json` classifies **132 persistent PostgreSQL tables** declared in the 92 `db/supabase/migrations/*.sql` files:

| Disposition | Count | Meaning |
| --- | ---: | --- |
| `exported_v1` | 26 | Included in the account-scoped server export |
| `global_catalog` | 32 | Shared catalog/configuration, not exported per account |
| `platform_ops` | 45 | Platform, worker, telemetry, or operational state |
| `excluded_with_intent` | 29 | Explicitly omitted; reasons identify scope gaps and recovery implications |

Public-schema keys remain unqualified for compatibility. Non-public schema keys are fully qualified, so `promotions` tables cannot be confused with public tables. Migration-only temporary tables are excluded from this persistent-schema count. The coverage test strips SQL comments and string literals before scanning, and includes a fixture for same-named tables in `public` and `promotions`.

This registry covers server migration tables only. It does **not** inventory SQLite tables, individual columns, or all user state, and it is not a full database disaster-recovery manifest. The separate paired PostgreSQL backup/restore path is responsible for database disaster recovery.

## Implemented pieces

- `api/src/portable_backup/contract.js` defines the static section allow-list and canonicalization rules.
- `api/src/portable_backup/export.js` streams profile-filtered sections in batches and emits counts/digests in a completion footer.
- `api/src/portable_backup/routes.js` mounts the authenticated, repeatable-read, read-only export transaction.
- Security integration corrected first-page bind parameters and settings pagination. Exports now have a 10-minute deadline, 30-second stalled-response bound, 64 MiB total NDJSON cap and one-million-record cap. Each API process admits one export at a time; excess requests receive `503 export_busy`. These are per-process limits, not a distributed budget. Limit failures abort without a successful completion footer. The paired PostgreSQL backups are separate and do not use these account-export limits.
- The app has portable archive, encryption, attachment-collection, and snapshot-coordination components, but the snapshot source remains an interface and they are not yet integrated into a complete backup flow.
- `api/src/portable_backup/coverage.json` records all 132 persistent migration tables and explicitly records the referral/credit export gap.

## Verification recorded for this review

| Command | Result |
| --- | --- |
| `cd api; node --test test/portable_backup_coverage.test.js` | 4 tests passed, including schema collision and SQL comment/string regression fixtures |

The broader API, Flutter, device, encryption interoperability, and restore gates have not been run as part of this review. Passing the coverage test verifies the migration-table classification inventory; it does not prove completeness of local app data or a working restore.
