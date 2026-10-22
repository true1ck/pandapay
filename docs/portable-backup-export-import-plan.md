# Portable backup and restore plan

22 October 2026 · Investigation and implementation plan · No backup/restore code changed

## Goal and meaning of “identical”

An authenticated user can export a portable backup from device A and restore it on a fresh device B, signed in to the **same account**, without device B having the original SMS inbox. After restoration, user-owned cards, transaction history and edits, categories/tags, budgets, commitments, review decisions, historical captured SMS and their financial effects, attachments, and relevant settings should match A at the backup's snapshot time. Counts, monetary totals, relationships, and user-visible states must reconcile. Device B must get its own credentials, device ID, SMS scan cursor, notification token, biometric setup, and platform permissions. “Identical” means identical portable app state, not duplicated device identity or the physical SMS inbox.

This is distinct from (1) a readable CSV/PDF report, (2) importing a bank statement, and (3) importing an SMS backup file. The existing ops `pg_dump`/restore drill is a whole-service disaster recovery mechanism, not a user file restore.

## Current behavior and evidence

| Surface | What it does now | Why it cannot clone a device |
| --- | --- | --- |
| `GET /export` | Returns selected transaction fields plus tag definitions and a small card projection; `all` means those sections. [API](../api/src/index.js#L10187-L10270) | Omits most fields and other user-owned tables. No format/version manifest or restore contract. |
| Export screen | Offers CSV, PDF, JSON, loads the entire response, stores bytes and preview, can copy to clipboard or write a plaintext temporary share file. [UI](../app/lib/features/import/data_export_screen.dart) | Large exports can exhaust memory; temporary plaintext and clipboard expose financial data. Text says JSON is a “complete structured backup,” which is inaccurate. |
| JSON/CSV statement import | Reads transaction-shaped rows, offers mapping/review, and submits transaction batches to the shared ingestion writer. [Decoder](../app/lib/data/transaction_import_pipeline.dart#L96-L188), [server](../api/src/statement_import.js) | It recreates selected transactions, not original cards, IDs, relationships, statuses, source observations, settings, or attachments. JSON nested objects are not a backup schema. |
| SMS backup import | Parses SMS XML/CSV/TXT, filters likely financial alerts, and ingests selected messages. [Parser](../app/lib/data/sms_backup_xml_parser.dart), [screen](../app/lib/features/sms_import/sms_backup_import_screen.dart) | Useful for external SMS history, but not a byte-for-byte local captured-SMS or app-state restore. |
| Sync & backup | Shows server ops backup/restore status; “Restore” leads to support. [UI](../app/lib/features/import/sync_backup_screen.dart#L115-L252) | No self-service import of an exported file. |

The current API builds arrays in memory, runs multiple queries without an explicit common snapshot, and sends a single JSON response. The app then copies that response into bytes and a preview. There is no row-count/completeness check. The CSV helper within `/export` also lacks the formula-cell protection in the existing [CSV utility](../api/src/csv.js); address that on the legacy report path independently.

### Coverage inventory to turn into an executable manifest

The inventory below is a starting audit, **not** a claim that every operational row should be copied verbatim. Before implementation, generate the final list from the deployed database schema and local SQLite schema, assigning every table/field an explicit `portable`, `rebuild`, `device-only`, `server-only`, or `sensitive-excluded` decision. Fail CI when a new user-owned table has no classification.

| State family | Examples and source | Proposed treatment |
| --- | --- | --- |
| Account/user choices | Profile, user settings, categories, tags, consent history, notification preferences/mutes; [domain schema](../db/supabase/migrations/0004_user_domain.sql#L10-L40), [settings](../db/supabase/migrations/0028_user_settings.sql), [tags](../db/supabase/migrations/20261020200000_transaction_tags.sql) | Export/restore portable values; preserve audit semantics for consents. Do not overwrite current legal acceptance silently. |
| Financial entities | Cards (full user-owned attributes), overrides, transactions (including deleted/ignored, links, manual corrections and source identities), splits, observations, points ledger, lounge usage, budgets/periods, recurring series; [domain schema](../db/supabase/migrations/0004_user_domain.sql#L54-L209), [later schema](../db/supabase/migrations/0040_budgets_instruments_recurring.sql) | Preserve canonical entities, stable IDs and relationships. Classify balances/caps/reports as either authoritative snapshots or recomputable projections, then compare after rebuild. |
| Ingestion/review provenance | Statement import metadata, SMS sources/facts/overrides, needs-review items, duplicate candidates, source observations and user decisions; [ingest schema](../db/supabase/migrations/0006_ingest.sql), [SMS facts](../db/supabase/migrations/20261021120000_sms_source_facts.sql) | Include enough portable provenance to prevent re-ingestion and preserve reviews; avoid copying worker/admin telemetry. |
| Local unsynced state | SQLite pending transactions/changes, local cards/categories/tags, commitments, financial entities, captured SMS and review decisions; [SQLite schema](../app/lib/data/local/app_database.dart), [financial store](../app/lib/data/local/financial_store.dart) | Prefer draining sync queues and verify zero pending. If offline export is supported, package unsynced records and operations with stable identities and replay rules; never silently omit them. |
| Files | Transaction attachment binaries and metadata; [attachment repository](../app/lib/data/local/transaction_attachments_repository.dart#L94-L116) | Include bytes under archive-relative names, hash them, restore into target app storage, and rewrite local paths. |
| Device and secrets | Auth tokens, device ID, push token, SMS provider cursor, biometric lock, local sync cursor; [token store](../app/lib/data/token_store.dart), [device identity](../app/lib/data/device_identity.dart), [SMS scanner](../app/lib/features/sms_import/sms_inbox_scanner.dart) | Never transfer. Require sign-in and permissions on B; register a new device and establish a new sync cursor. Historical SMS records may transfer, but no provider ID/checkpoint from A. |
| Shared/system state | Card catalogue, merchant/reference rules, admin data, worker jobs, global ops backups | Reference by stable key/version or rebuild on B; do not package the service's shared database. Validate missing/retired references during restore. |

## Recommended design

Build on the app's existing entity and ingestion logic, with a **new portable-backup protocol**. Do not send backup JSON through the statement importer, and do not repurpose `pg_dump` as a user-facing archive. General libraries can supply ZIP, hashing and authenticated encryption, but no open source library knows PandaPay's ownership, FK graph, SMS provenance or restore semantics.

### File contract (`.pandapay-backup`)

1. A versioned manifest: format/schema version, app/server versions, creation and snapshot times, source account identifier binding, scope/completeness flags, section names, counts, byte lengths, SHA-256 digests, archive-wide integrity metadata, and required capabilities. Avoid putting sensitive details in an unencrypted outer header.
2. Separate deterministic, bounded sections (for example NDJSON per entity family) and attachment blobs named by generated archive IDs, not local absolute paths. Explicit field schemas and a migration path from supported older versions; reject newer unknown required sections.
3. Authenticated encryption for the entire user file with a user-held passphrase and a vetted password KDF; choose parameters after mobile benchmarking. Wrong password, truncation and tampering must fail before mutation. Never put tokens or passphrase in the archive or logs. A checksum alone detects accidents, not deliberate tampering.
4. Hard limits for entry count, expanded size, nesting and decompression ratio; reject absolute paths, `..`, duplicate paths and symlinks. Parse into staging only. Treat manifest and all file contents as untrusted input.
5. A preview after decryption showing section counts, snapshot age, account match, missing items, and whether the file is complete. The app must say “partial” when offline changes, attachments or a section were omitted.

For a server-backed account, take server rows in a single PostgreSQL `REPEATABLE READ READ ONLY` transaction or equivalent snapshot. Query every selected family under the authenticated profile filter, with deterministic ordering and bounded cursor/streaming output. Record counts and digests while writing. Coordinate local capture at a defined watermark: pause/serialize local writes briefly, capture SQLite with its backup API or a consistent read transaction, and record queued operations. Do not just copy a live WAL database file. A short-lived server snapshot/job plus streaming download may be required for large accounts; design expiry, authenticated access, cleanup, cancellation, rate limits and resumability before choosing the final transport.

The default v1 product policy should be **same-account restore onto a fresh install**. A different-account migration is a distinct feature because auth identity, server-owned rows, consent records, referrals and immutable provenance need explicit remapping and authorization. On the same account, existing server data is already available after sign-in; the restore must reconcile the snapshot with that server state and recover local-only data without doubling transactions. It must not roll back newer server changes without an explicit replace operation and a safety snapshot.

### Restore algorithm

1. Authenticate the target account, select the backup file, decrypt, validate version, hashes, completeness, account binding, sizes, schema and cross-record references. Show a dry-run diff and exact replacement/merge consequences. Keep the existing statement/SMS file import entry points separate.
2. Stage all records and attachments. Compute a dependency-ordered restore plan: categories/tags and cards before transactions; transactions before splits/observations/tag links/attachments; then budgets/commitments and other dependent state. Preserve IDs where safe and map IDs deterministically when required. Reject orphan references and unknown enum values rather than dropping rows.
3. Make server application atomic per account wherever possible: a guarded restore session, ownership checks, idempotency key, transactional apply, optimistic guard against changes since preview, and an explicit conflict policy. If the complete graph cannot fit one transaction, use staged tables plus one commit/swap boundary; do not report success after partial application.
4. Restore local SQLite through a staging DB and atomic swap or equivalent transactional mechanism. Rebase attachments to B's storage; verify file hashes. Regenerate device ID, sync cursor and platform registrations. Do not replay historical SMS as new financial transactions when canonical transactions/observations are already present.
5. Refresh providers and recompute only declared derived state. Compare manifest counts, section hashes or canonical digests, relationship counts, monetary totals by kind/status/card/month, tag links, review counts and attachment bytes. Show a detailed result with any intentionally excluded device-only state.
6. Retain a pre-restore rollback snapshot until verification succeeds. Failed validation must leave the target unchanged; interrupted restore must resume or roll back deterministically. Repeat restore of the same archive must be idempotent.

### Existing external imports remain useful

The [shared document-import pipeline](import-scenario-matrix.md) already handles PDF text/OCR, CSV/TSV, XLSX, JSON transaction lists and screenshots through normalization, review, mapping, batching and idempotent ingestion. The SMS XML/CSV importer is a separate message decoder. Keep improving those adapters for external data, but label them “Import transactions” or “Import SMS history,” not “Restore backup.” Their job is interpretation and merge, so they cannot promise exact cloning. Maintain visible unresolved rows and totals; never silently discard unsupported sections. Add fixtures for export-like nested JSON and new bank layouts only where the source semantics can be mapped safely.

## Implementation sequence, export first

| Phase | Deliverable | Completion gate |
| --- | --- | --- |
| 0. Contract and inventory | Machine-readable table/field classification, v1 manifest/schema, account/replace/merge policy, representative full-data fixture and golden expected counts. Correct current UI text to describe JSON as a limited export. | Every persisted user-owned field is classified, including local files and unsynced state. |
| 1. Export correctness | Snapshot-consistent server extractor, coordinated local snapshot, full section serialization, streaming archive writer, integrity checks, encrypted file, progress/cancel UI. Preserve legacy `/export` CSV/JSON/PDF routes for report compatibility; harden CSV formula escaping. | Two exports of unchanged data have equivalent canonical content; large histories do not require full in-memory copies; explicit failure if a section is incomplete. |
| 2. Export verification | Independent archive inspector validates schema, counts, hashes and referential integrity; sampled and maximum-size device tests. | Backup self-check passes before “ready to share”; corruption/truncation fails clearly. |
| 3. Same-account restore | Staging, dry-run preview, conflict policy, atomic/idempotent server apply, local restore and attachment rebase, result reconciliation. | Fresh B with no SMS restores the complete fixture to the same portable state as A. |
| 4. External import improvements | Retain existing review pipeline; add only proven format adapters, stronger source-level reconciliation, coverage labels and recovery for unsupported files. | Existing import regression suite still passes; no previously accepted statement/SMS format regresses. |
| 5. Rollout | Feature flag, staged migration, telemetry limited to counts/error codes (no financial content), support runbook, rollback path. | Staging device-to-device drill, offline/online interruption drill, old/new app version test and production canary pass. |

## Required test matrix

- Empty account; heavy account with tens of thousands of transactions; multiple cards; deleted/ignored/refunded/split transactions; exact duplicate candidates and SMS+statement observations; custom categories/tags; budgets/recurring/commitments; attachments; review queue; pending local writes.
- Device A with SMS to fresh device B without SMS permission or messages. Verify restored history and decisions, no new SMS scan duplicate, and B's independent device registration.
- Backup while transactions are added/edited, while sync is pending, and while the app is offline. Either produce a consistent marked snapshot or fail explicitly.
- Wrong account, wrong passphrase, modified bytes, truncated file, unsupported newer version, missing archive entry, ZIP bomb/path traversal, interrupted download/upload, low storage, app killed mid-restore, repeated restore, and conflict with newer server edits.
- Compare not only record counts but stable canonical values and UI outcomes: balances, spending, card utilization, rewards, budgets, tags, review states and attachments. Record deliberate differences such as biometric setup and push token.
- Run legacy PDF/CSV/JSON export and external PDF/CSV/XLSX/JSON/SMS import regression tests. Their files must remain recognized as reports/import sources, never auto-applied as a complete backup.

## Open source and platform research

The [Dart `archive` package](https://pub.dev/packages/archive) supplies archive formats and file-streaming APIs; use it only after checking its current extraction/security behavior and pinning an audited version. [PostgreSQL repeatable-read semantics](https://www.postgresql.org/docs/18/transaction-iso.html) support a consistent server snapshot. The [SQLite Online Backup API](https://www.sqlite.org/backup.html) supports a consistent local database snapshot. [libsodium secretstream](https://doc.libsodium.org/secret-key_cryptography/secretstream) is an example of audited authenticated streaming encryption; select a maintained Flutter/native binding and password KDF after compatibility and performance tests. [OWASP mobile backup guidance](https://mas.owasp.org/MASWE-0006/) and [Android backup guidance](https://developer.android.com/identity/data/autobackup) support excluding credentials and device-specific state. These are building blocks, not a drop-in PandaPay backup/restore solution.

## Decisions to lock before Phase 1

The recommended v1 defaults are same-account restore, encrypted portable archive, complete server plus local state, and a fresh-device target. Product decisions still needed: whether an existing populated target can be replaced (with a safety backup) or only merged, whether offline export is allowed before queues drain, and whether historical raw SMS bodies should be included by default given their sensitivity. The format must record those choices explicitly so a file never appears “complete” when it is not.
