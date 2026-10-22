# Portable backup and restore implementation handoff for Luna 5.6 Hive

23 October 2026 · Authoritative implementation plan · Export first · Same-account fresh-device restore

This document is an implementation handoff, not a completion claim. Luna 5.6 Hive is the parent and integration owner. Luna must inspect the current working tree before editing, preserve all unrelated uncommitted changes, freeze the v1 contract, and then spawn exactly three agents for each implementation wave. Agents share one checkout and must have disjoint file ownership. Luna reviews every diff, owns shared integration files, runs the final gates, and updates this document only with verified results.

## Fixed v1 product decisions

These decisions remove the open-ended choices that would otherwise make independent agents implement incompatible backup semantics.

1. **Account boundary:** v1 restores only to the same authenticated PandaPay account that created the backup. Cross-account migration is out of scope.
2. **Target boundary:** v1 supports a fresh installation or a fresh portable-data namespace. If portable local data already exists, show the preview and stop. Populated-target replace/merge is a later feature.
3. **Complete export boundary:** v1 requires network access and drains every local transaction, tag, settings and sync outbox first. If a queue cannot drain, the complete export stops with the exact pending count and recovery action. It must not label an offline or incomplete file as complete.
4. **SMS boundary:** complete backup includes PandaPay's durable historical SMS capture/provenance rows and review decisions inside the encrypted archive. It does not copy Android's physical inbox or provider IDs. Restoring those rows must never run ingestion again or create another financial transaction.
5. **Conflict rule:** an existing server row with the same stable ID and canonical digest is a no-op; a missing row is restored; a different digest, ownership mismatch, or newer conflicting server revision blocks the commit. V1 never silently overwrites or duplicates a divergent row.
6. **Identity and secrets:** access/refresh tokens, secure-storage values, installation/device ID, push token, biometric state, SMS provider cursor, platform permissions and local sync cursor are excluded. Device B signs in, registers itself, and starts a new sync cursor.
7. **Derived state:** authoritative user records and audit/provenance required for behavior are restored. Declared projections and caches are rebuilt, then compared with backup reconciliation totals. A mismatch is a restore failure.
8. **Encryption:** `.pandapay-backup` is always authenticated and passphrase-encrypted. Use Argon2id for password derivation and an audited streaming AEAD such as libsodium XChaCha20-Poly1305 secretstream. The selected binding must work on supported Android/iOS versions and pass cross-runtime test vectors before UI integration.
9. **Compatibility:** current CSV/PDF/JSON reports and external statement/SMS imports remain available and keep their existing semantics. A portable backup has its own media type, extension, schema and restore pipeline.
10. **Recovery scope:** v1 must restore server rows that are missing after the export, which is verified by a destructive-recovery fixture. It does not overwrite a row modified after the backup.

## Completion definition

The feature is complete only when all of the following are true:

- Device A creates a self-verified encrypted backup without buffering the entire account in memory.
- A fresh device B, signed into the same account and with no SMS permission/inbox, restores the maximal fixture.
- Canonical section digests, portable row counts, relationships, monetary totals, attachment hashes, review states, categories/tags, cards, budgets and user-visible projections match A at the snapshot time.
- Expected differences are limited to the documented device-only fields.
- Wrong passwords, corruption, account mismatch, unsupported versions, dangerous archive paths, low storage, cancellation, process death and server conflicts fail without partially mutating portable state.
- Repeating export does not omit data; repeating restore of the same backup is idempotent.
- Existing report export and external PDF/CSV/XLSX/JSON/SMS import suites still pass.

## Luna/Hive operating contract

Luna must create `docs/portable-backup-implementation-status.md` before coding. It records the starting `git status`, unrelated modified files, the frozen contract version, agent ownership, completed gates, exact commands/results and remaining external blockers. Agents must report changed files, tests run, failures and risks. A claim such as “tests pass” without the command and result count is insufficient.

Agents must not create worktrees, commit, deploy, revert another agent's changes, run repository-wide formatters, or edit outside their ownership. If an owned task needs a shared file, the agent reports the required edit to Luna. Luna alone owns:

- `api/src/index.js` and shared API middleware/configuration;
- `app/lib/app/providers.dart`, app navigation/routes and shared settings wiring;
- `app/pubspec.yaml` / lockfile dependency decisions;
- the v1 archive/JSON/SQL contract and this handoff;
- cross-agent conflict resolution, end-to-end integration and release claims.

Before spawning implementation agents, Luna freezes these artifacts:

- `docs/portable-backup-format-v1.md` — normative archive, encryption, canonicalization and compatibility specification;
- `api/src/portable_backup/coverage.json` — machine-readable server/local table and field classification;
- `api/src/portable_backup/schema/manifest-v1.schema.json` and section schemas;
- cross-runtime golden fixture and expected canonical digests/counts/totals;
- endpoint request/response examples and stable error codes.

The coverage test must fail when a migration or local SQLite table/column is absent from the classification. Every field is one of `portable`, `rebuild`, `device_only`, `server_only`, or `sensitive_excluded`, with a reason.

## Canonical v1 archive contract

The normative format document must lock these rules before agents implement readers or writers:

- Outer file begins with a small versioned encryption header containing only magic/version, KDF identifier/parameters, salt and stream header. No account, card, SMS or section metadata is readable before decryption.
- Decrypted payload is a bounded ZIP archive. Paths are ASCII, forward-slash, relative and unique. Reject absolute paths, `..`, backslashes, drive prefixes, symlinks, duplicates, unknown required entries, excessive nesting, expanded-size/entry-count/decompression-ratio violations and trailing unauthenticated bytes.
- `manifest.json` records format version, backup UUID, account binding, created/snapshot times, app/server/schema versions, completeness, server revision, section names, record counts, plaintext byte lengths, SHA-256 digests, attachment inventory, required capabilities and declared exclusions.
- Structured sections use UTF-8 NDJSON with LF endings, snake_case field names, deterministic field order and stable record ordering. UUIDs are lowercase strings; money/decimal values are canonical decimal strings; timestamps are UTC RFC 3339 with preserved precision; absent nullable fields are explicit `null`; booleans are JSON booleans.
- Section hashes cover exact plaintext section bytes. Encryption is intentionally randomized, so two valid encrypted files need not be byte-identical. Their canonical decrypted section digests must match when state is unchanged.
- Attachments use archive-generated IDs and content-derived names. Original local absolute paths never enter the archive. Metadata preserves user-visible filename/type where safe. Zero-byte and non-ASCII filenames have explicit tests.
- The reader validates the complete archive, schemas, hashes, byte counts, ownership binding and cross-section foreign keys before offering Commit.

## Server export transport

Add a dedicated authenticated route module under `api/src/portable_backup/`; keep legacy `GET /export` unchanged except for the separately tracked CSV hardening fix. `GET /portable-backups/export-v1` streams a typed NDJSON envelope under one `REPEATABLE READ READ ONLY` transaction:

1. header with schema/version and snapshot revision;
2. deterministic records grouped by section;
3. footer with per-section counts/digests and completion marker.

The client writes the stream incrementally to section staging files. A missing/invalid footer makes the server portion unusable. Use database cursors or bounded batches and backpressure; never materialize all rows. Apply explicit `profile_id` filters even under RLS. Close the transaction and discard staging on cancellation or disconnect. Rate-limit export creation and log only backup/session IDs, counts, sizes, timings and error codes.

The client backup coordinator performs: authenticate -> drain/verify all outboxes -> capture a consistent local SQLite snapshot/read transaction -> stream the authoritative server snapshot -> collect attachment files -> assemble canonical sections -> self-verify -> encrypt/finish -> atomically rename the final file -> share. Temporary plaintext stays only in app-private storage, is removed on success/failure/startup cleanup, and is never copied to the clipboard.

## Restore protocol and API

Use a dedicated staged restore protocol; never route `.pandapay-backup` through `transaction_import_pipeline.dart`.

- `POST /portable-backups/restore-sessions` authenticates the account and creates/resumes a session from backup ID, manifest metadata and an idempotency key. It does not change live user data.
- `PUT /portable-backups/restore-sessions/:id/sections/:section` incrementally uploads one decrypted, client-validated server section as NDJSON. The server independently validates schema/ownership, stages rows, checks declared count/digest and makes repeat upload of the same section idempotent. Attachments and local-only sections are never uploaded.
- `GET /portable-backups/restore-sessions/:id/preview` returns section counts, no-ops, missing rows, blocking conflicts, declared exclusions, snapshot age and the server revision to use for commit.
- `POST /portable-backups/restore-sessions/:id/commit` requires the preview revision (`If-Match` or equivalent), takes an account-level advisory lock, rechecks ownership/digests/revision and applies the staged dependency graph in one database transaction.
- `GET /portable-backups/restore-sessions/:id/status` supports crash/retry recovery.
- `DELETE /portable-backups/restore-sessions/:id` cancels and cleans staging.

Add an additive migration for restore sessions, staged records, committed backup ledger and expiry/cleanup metadata. The committed ledger is unique by account plus backup ID. Retry after an uncertain response returns the recorded result. Expired/uncommitted staging is removable without touching live rows. Do not call commit if preview has a conflict.

Dependency order is: user categories/tags/settings -> cards/overrides -> canonical transactions -> splits/observations/tag links/provenance -> budgets/recurring/commitments/review state -> declared rebuilds. Preserve stable IDs when ownership and schema permit it. Reject orphan references and unknown enum values.

For local state, inspect/decrypt/validate into an app-private staging area. Stage portable SQLite rows separately from device-only tables and attachment files. After the server commit succeeds, apply the local portable namespace transactionally, move verified attachment files into target storage, rebase paths, generate a new device/sync identity, perform a full pull from a fresh cursor, rebuild projections and run reconciliation. A failed local finalization keeps enough restore-session state to retry; it must not re-commit server economic events.

## Parallel implementation waves

Only independent work runs in parallel. Contract freeze and each integration gate are sequential.

### Wave 0 — Luna freezes the contract

- [ ] Record working-tree baseline and unrelated changes.
- [ ] Generate the complete server/local/file inventory and coverage classifications.
- [ ] Write format v1, JSON schemas, canonicalization examples and stable error codes.
- [ ] Build the maximal fixture plus destructive-recovery, large-history and adversarial variants.
- [ ] Decide and document supported app/schema version matrix and size limits from measured device tests.
- [ ] Run the coverage/schema/golden tests before allowing implementation to branch.

### Wave 1 — complete export

#### Agent A — server snapshot and legacy CSV safety

Own new files under `api/src/portable_backup/`, focused API tests, and the minimum legacy CSV helper/test change. Do not edit `api/src/index.js`; Luna mounts the route.

- Implement the authenticated repeatable-read streamed export envelope with deterministic sections, explicit ownership filters, bounded memory, counts/digests and completion footer.
- Export every server field marked `portable`; emit reference/version data required to validate shared catalogue links.
- Fail the export if any required section query fails or a count/digest cannot be finalized.
- Replace the inline legacy CSV escaping with the hardened shared formula-safe CSV utility and keep legacy output compatibility tests.
- Test snapshot concurrency, disconnect/cancel cleanup, empty/maximal/large accounts, RLS isolation and deterministic canonical output.

#### Agent B — local snapshot, archive, attachments and crypto

Own new Dart files under `app/lib/data/portable_backup/` and their unit tests. Request dependency changes from Luna; do not edit `pubspec.yaml` directly.

- Implement manifest/schema models, canonical NDJSON writer, streaming ZIP assembly, Argon2id + authenticated streaming encryption, incremental SHA-256 and independent self-verification.
- Snapshot every local field marked `portable`, after the coordinator confirms all outboxes are drained. Refuse “complete” when queues are nonzero.
- Collect attachments incrementally, rebase archive paths, enforce size/path limits, and clean app-private staging on every exit path.
- Add golden interop vectors and tests for wrong passphrase, tamper, truncation, duplicate/path-traversal entries, oversized expansion, cancellation, low storage and process restart cleanup.

#### Agent C — independent inspector, fixtures and export UX

Own new backup inspector/test-fixture code, `app/lib/features/import/data_export_screen.dart`, new export-only widgets/screens and focused widget tests. Coordinate repository interfaces with Agent B; do not edit providers/routes.

- Separate “Portable backup” from readable CSV/PDF/JSON reports and remove the inaccurate “complete structured backup” claim from report JSON.
- Implement passphrase creation/confirmation, scope explanation, progress by stage, cancellation, explicit pending-sync errors, successful self-check summary and share action.
- Never render or retain a full raw backup preview and never offer Copy for a portable backup.
- Build an inspector that independently reads writer output and verifies manifest, section digests/counts, relationships and exclusions.
- Add export UI tests for signed-out, pending, failure, retry, cancel, success and cleanup states.

#### Wave 1 integration gate — Luna

- [ ] Inspect all three diffs and reconcile only through the frozen contract.
- [ ] Mount the server route and wire Flutter providers/repositories/dependencies.
- [ ] Run unchanged-state double export and compare canonical decrypted digests.
- [ ] Run empty, maximal, 50,000-transaction, concurrent-write and attachment fixtures.
- [ ] Confirm bounded memory, private temporary files and cleanup on Android and iOS.
- [ ] Do not start restore implementation until the independent inspector accepts the produced file.

### Wave 2 — same-account restore

#### Agent A — server staging and atomic apply

Own the additive restore migration, new server restore modules and focused API/real-PostgreSQL tests. Luna owns the route mount.

- Implement create/stage, preview, commit, status, cancel/expiry and committed-ledger idempotency.
- Validate account binding, schema, canonical digests, ownership and the complete FK graph before live mutation.
- Apply missing records in dependency order under an account lock and one commit transaction; equal digests are no-ops and divergent/newer records are blocking conflicts.
- Prove another account cannot stage/preview/commit rows; prove retry after committed-but-response-lost returns the original result.

#### Agent B — local restore and attachment finalization

Own new local restore/staging modules and focused data tests.

- Decrypt and validate to private staging, enforce archive limits, and produce the local part of the preview without mutation.
- Apply only classified portable tables to a fresh namespace; keep/generate device-only state independently.
- Restore attachments with verified hashes and rebased paths. Insert historical SMS/provenance without invoking parsers or transaction writers.
- Support process death after server commit: resume local finalization and reconciliation without another economic write.

#### Agent C — restore UX and end-to-end harness

Own new restore screens/widgets, file routing for `.pandapay-backup`, focused UI tests and the device A/B harness. Luna owns navigation/provider integration.

- Implement file selection, password, validation, preview, conflict display, Commit, resumable status and reconciliation result.
- Stop populated local targets in v1 with a clear fresh-install requirement.
- Keep “Import transactions” and “Import SMS history” as separate actions and route backup-looking JSON/archive files to the correct explanation.
- Exercise A with SMS -> encrypted backup -> fresh B without SMS permission -> restore -> full projection comparison.

#### Wave 2 integration gate — Luna

- [ ] Apply migrations on clean and upgraded PostgreSQL and verify real roles/RLS.
- [ ] Run no-op, missing-row recovery, newer-row conflict, wrong-account, repeated commit and lost-response retries.
- [ ] Kill the app at each restore boundary and prove retry or rollback.
- [ ] Compare canonical data plus Home, Activity, cards, bills, budgets, rewards, Needs Review, tags and attachment outcomes.
- [ ] Confirm device B has new tokens/device ID/SMS cursor and creates zero duplicate transactions.

### Wave 3 — compatibility, hardening and rollout

Agents may again divide API security/performance, mobile compatibility/accessibility and external-import regression work. They must not expand v1 into populated-target merge or cross-account migration.

- [ ] Run complete API, Flutter and console suites plus targeted real-DB migration/RLS tests.
- [ ] Preserve external PDF/CSV/TSV/XLSX/JSON/screenshot and SMS XML/CSV/TXT behavior.
- [ ] Add format-version N-1 reader fixtures and reject unknown required N+1 capabilities before mutation.
- [ ] Add metrics limited to counts, sizes, durations, stage and error codes; never log passphrases, raw SMS, merchant text, card data, section content or attachment names.
- [ ] Place export and restore behind independent feature flags with server kill switches.
- [ ] Complete staging device-to-device, corruption, resource pressure, interruption and rollback drills before a canary.

## Mandatory test fixtures and gates

The golden fixture includes two cards, archived/default state, overrides, transactions in every supported status/kind/source, repeated same-value transactions, splits, refunds/links, observations, tags and aliases, custom categories, points/lounge state, budgets/periods, recurring/commitment state, SMS facts/captured messages/review decisions, statement provenance, notifications/settings and attachments including binary, zero-byte and non-ASCII names.

Also maintain fixtures for empty account, 50,000 transactions, pending outboxes, a concurrent writer, A-with-SMS/B-without-permission, server rows deleted after export, and a server row edited after export. For every valid fixture store expected section record counts, exact canonical digests, relationship counts, attachment bytes and monetary totals by entry kind/status/card/month.

Security/adversarial tests must prove that wrong password, modified cipher text, modified plaintext section, truncation, unknown version/capability, missing/duplicate archive entries, path traversal, absolute paths, symlinks, decompression bombs, excessive records/nesting, malformed decimals/timestamps/UUIDs, account mismatch and orphan references all fail before live mutation.

Verification commands must be discovered from current package scripts rather than assumed. At minimum Luna records results for `git diff --check`, full API tests, targeted real PostgreSQL tests under application and restore roles, Flutter formatting/analyze/full tests, and any console tests affected by shared settings. Skipped DB/device gates are reported as blockers, not converted into passes.

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
| Account/user choices | Profile, user settings, categories, tags, consent history, notification preferences/mutes; [domain schema](../db/supabase/migrations/0004_user_domain.sql#L10-L40), [settings](../db/supabase/migrations/0028_user_settings.sql), [tags](../db/supabase/migrations/20261020200000_transaction_tags.sql) | Export/restore portable values. Consent rows remain immutable historical audit facts; restoring history must not grant a newer/current policy version or reactivate a revoked consent. |
| Financial entities | Cards (full user-owned attributes), overrides, transactions (including deleted/ignored, links, manual corrections and source identities), splits, observations, points ledger, lounge usage, budgets/periods, recurring series; [domain schema](../db/supabase/migrations/0004_user_domain.sql#L54-L209), [later schema](../db/supabase/migrations/0040_budgets_instruments_recurring.sql) | Preserve canonical entities, stable IDs and relationships. Classify balances/caps/reports as either authoritative snapshots or recomputable projections, then compare after rebuild. |
| Ingestion/review provenance | Statement import metadata, SMS sources/facts/overrides, needs-review items, duplicate candidates, source observations and user decisions; [ingest schema](../db/supabase/migrations/0006_ingest.sql), [SMS facts](../db/supabase/migrations/20261021120000_sms_source_facts.sql) | Include enough portable provenance to prevent re-ingestion and preserve reviews; avoid copying worker/admin telemetry. |
| Local unsynced state | SQLite pending transactions/changes, local cards/categories/tags, commitments, financial entities, captured SMS and review decisions; [SQLite schema](../app/lib/data/local/app_database.dart), [financial store](../app/lib/data/local/financial_store.dart) | Drain every outbox and verify zero pending before v1 export. If a queue cannot drain, stop with a visible incomplete-backup error. Portable local records, historical SMS and decisions are still included after the drain. |
| Files | Transaction attachment binaries and metadata; [attachment repository](../app/lib/data/local/transaction_attachments_repository.dart#L94-L116) | Include bytes under archive-relative names, hash them, restore into target app storage, and rewrite local paths. |
| Device and secrets | Auth tokens, device ID, push token, SMS provider cursor, biometric lock, local sync cursor; [token store](../app/lib/data/token_store.dart), [device identity](../app/lib/data/device_identity.dart), [SMS scanner](../app/lib/features/sms_import/sms_inbox_scanner.dart) | Never transfer. Require sign-in and permissions on B; register a new device and establish a new sync cursor. Historical SMS records may transfer, but no provider ID/checkpoint from A. |
| Shared/system state | Card catalogue, merchant/reference rules, admin data, worker jobs, global ops backups | Reference by stable key/version or rebuild on B; do not package the service's shared database. Validate missing/retired references during restore. |

## Recommended design

Build on the app's existing entity and ingestion logic, with a **new portable-backup protocol**. Do not send backup JSON through the statement importer, and do not repurpose `pg_dump` as a user-facing archive. General libraries can supply ZIP, hashing and authenticated encryption, but no open source library knows PandaPay's ownership, FK graph, SMS provenance or restore semantics.

### File contract (`.pandapay-backup`)

1. A versioned manifest: format/schema version, app/server versions, creation and snapshot times, source account identifier binding, scope/completeness flags, section names, counts, byte lengths, SHA-256 digests, archive-wide integrity metadata, and required capabilities. Avoid putting sensitive details in an unencrypted outer header.
2. Separate deterministic, bounded sections (for example NDJSON per entity family) and attachment blobs named by generated archive IDs, not local absolute paths. Explicit field schemas and a migration path from supported older versions; reject newer unknown required sections.
3. Authenticated encryption for the entire user file with a user-held passphrase, Argon2id and an audited streaming AEAD such as libsodium XChaCha20-Poly1305 secretstream. Freeze measured KDF parameters in format v1 after supported-device benchmarking. Wrong password, truncation and tampering must fail before mutation. Never put tokens or passphrase in the archive or logs. A checksum alone detects accidents, not deliberate tampering.
4. Hard limits for entry count, expanded size, nesting and decompression ratio; reject absolute paths, `..`, duplicate paths and symlinks. Parse into staging only. Treat manifest and all file contents as untrusted input.
5. A preview after decryption showing section counts, snapshot age, account match, missing items and completeness. V1 refuses creation or restore when offline changes, attachments or a required section were omitted; it does not produce a partial portable backup.

For a server-backed account, take server rows in a single PostgreSQL `REPEATABLE READ READ ONLY` transaction. Query every selected family under the authenticated profile filter, with deterministic ordering and bounded cursor/streaming output. Record counts and digests while writing a typed NDJSON response with a mandatory completion footer. Coordinate local capture after all queues drain: capture SQLite with its backup API or a consistent read transaction. Do not copy a live WAL database file. Cancellation, disconnect, missing footer or a changed precondition makes that attempt unusable and cleans staging.

The v1 product policy is **same-account restore onto a fresh install**. A different-account migration is a distinct feature because auth identity, server-owned rows, consent records, referrals and immutable provenance need explicit remapping and authorization. On the same account, existing server data may already be available after sign-in; restore treats matching rows as no-ops, recreates missing rows, and blocks divergent/newer rows. It recovers local-only data without doubling transactions.

### Restore algorithm

1. Authenticate the target account, select the backup file, decrypt, validate version, hashes, completeness, account binding, sizes, schema and cross-record references. Show a dry-run diff of matching no-ops, missing rows to restore and blocking conflicts. Keep the existing statement/SMS file import entry points separate.
2. Stage all records and attachments. Compute a dependency-ordered restore plan: categories/tags and cards before transactions; transactions before splits/observations/tag links/attachments; then budgets/commitments and other dependent state. Preserve IDs where safe and map IDs deterministically when required. Reject orphan references and unknown enum values rather than dropping rows.
3. Make server application atomic per account wherever possible: a guarded restore session, ownership checks, idempotency key, transactional apply, optimistic guard against changes since preview, and an explicit conflict policy. If the complete graph cannot fit one transaction, use staged tables plus one commit/swap boundary; do not report success after partial application.
4. Restore local SQLite through a staging DB and atomic swap or equivalent transactional mechanism. Rebase attachments to B's storage; verify file hashes. Regenerate device ID, sync cursor and platform registrations. Do not replay historical SMS as new financial transactions when canonical transactions/observations are already present.
5. Refresh providers and recompute only declared derived state. Compare manifest counts, section hashes or canonical digests, relationship counts, monetary totals by kind/status/card/month, tag links, review counts and attachment bytes. Show a detailed result with any intentionally excluded device-only state.
6. Retain staged restore state until verification succeeds. Failed validation must leave live state unchanged; interrupted restore must resume deterministically. Repeat restore of the same archive must be idempotent. A populated-target replace mode and its safety snapshot are out of v1 scope.

### Existing external imports remain useful

The [shared document-import pipeline](import-scenario-matrix.md) already handles PDF text/OCR, CSV/TSV, XLSX, JSON transaction lists and screenshots through normalization, review, mapping, batching and idempotent ingestion. The SMS XML/CSV importer is a separate message decoder. Keep improving those adapters for external data, but label them “Import transactions” or “Import SMS history,” not “Restore backup.” Their job is interpretation and merge, so they cannot promise exact cloning. Maintain visible unresolved rows and totals; never silently discard unsupported sections. Add fixtures for export-like nested JSON and new bank layouts only where the source semantics can be mapped safely.

## Implementation sequence, export first

| Phase | Deliverable | Completion gate |
| --- | --- | --- |
| 0. Contract and inventory | Machine-readable table/field classification, v1 manifest/schema, frozen same-account/fresh-target rules, representative full-data fixture and golden expected counts. Correct current UI text to describe JSON as a limited report export. | Every persisted user-owned field is classified, including local files and outbox behavior. |
| 1. Export correctness | Snapshot-consistent server extractor, coordinated local snapshot, full section serialization, streaming archive writer, integrity checks, encrypted file, progress/cancel UI. Preserve legacy `/export` CSV/JSON/PDF routes for report compatibility; harden CSV formula escaping. | Two exports of unchanged data have equivalent canonical content; large histories do not require full in-memory copies; explicit failure if a section is incomplete. |
| 2. Export verification | Independent archive inspector validates schema, counts, hashes and referential integrity; sampled and maximum-size device tests. | Backup self-check passes before “ready to share”; corruption/truncation fails clearly. |
| 3. Same-account restore | Staging, dry-run preview, conflict policy, atomic/idempotent server apply, local restore and attachment rebase, result reconciliation. | Fresh B with no SMS restores the complete fixture to the same portable state as A. |
| 4. External import improvements | Retain existing review pipeline; add only proven format adapters, stronger source-level reconciliation, coverage labels and recovery for unsupported files. | Existing import regression suite still passes; no previously accepted statement/SMS format regresses. |
| 5. Rollout | Feature flag, staged migration, telemetry limited to counts/error codes (no financial content), support runbook, rollback path. | Staging device-to-device drill, offline/online interruption drill, old/new app version test and production canary pass. |

## Required test matrix

- Empty account; heavy account with tens of thousands of transactions; multiple cards; deleted/ignored/refunded/split transactions; exact duplicate candidates and SMS+statement observations; custom categories/tags; budgets/recurring/commitments; attachments; review queue; pending local writes.
- Device A with SMS to fresh device B without SMS permission or messages. Verify restored history and decisions, no new SMS scan duplicate, and B's independent device registration.
- Backup while transactions are added/edited, while sync is pending, and while the app is offline. V1 must wait for safe local writes, drain sync, or fail explicitly; it must never emit a “complete” file from pending/offline state.
- Wrong account, wrong passphrase, modified bytes, truncated file, unsupported newer version, missing archive entry, ZIP bomb/path traversal, interrupted download/upload, low storage, app killed mid-restore, repeated restore, and conflict with newer server edits.
- Compare not only record counts but stable canonical values and UI outcomes: balances, spending, card utilization, rewards, budgets, tags, review states and attachments. Record deliberate differences such as biometric setup and push token.
- Run legacy PDF/CSV/JSON export and external PDF/CSV/XLSX/JSON/SMS import regression tests. Their files must remain recognized as reports/import sources, never auto-applied as a complete backup.

## Open source and platform research

The [Dart `archive` package](https://pub.dev/packages/archive) supplies archive formats and file-streaming APIs; use it only after checking its current extraction/security behavior and pinning an audited version. [PostgreSQL repeatable-read semantics](https://www.postgresql.org/docs/18/transaction-iso.html) support a consistent server snapshot. The [SQLite Online Backup API](https://www.sqlite.org/backup.html) supports a consistent local database snapshot. [libsodium secretstream](https://doc.libsodium.org/secret-key_cryptography/secretstream) is an example of audited authenticated streaming encryption; select a maintained Flutter/native binding and password KDF after compatibility and performance tests. [OWASP mobile backup guidance](https://mas.owasp.org/MASWE-0006/) and [Android backup guidance](https://developer.android.com/identity/data/autobackup) support excluding credentials and device-specific state. These are building blocks, not a drop-in PandaPay backup/restore solution.

## Locked choices and deferred work

The v1 choices are fixed at the top of this document: same account, fresh target, encrypted complete server-plus-local archive, online queue drain, historical PandaPay-captured SMS included, missing server rows restored, and divergent/newer rows blocked. Populated-target merge/replace, cross-account migration, offline partial backup and unencrypted export are explicitly deferred. An agent must not add any of those modes while completing v1.

## Copy-ready prompt for Luna 5.6 Hive

> Implement the PandaPay portable backup and restore feature in `C:\Users\sujay\CKProjects\PandaPay` using `docs/portable-backup-export-import-plan.md` as the authoritative contract. You are Luna 5.6 Hive, the parent and final integration owner. Inspect and preserve the complete current working tree before editing. Create `docs/portable-backup-implementation-status.md`, freeze the v1 coverage manifest, format/schema, canonicalization, endpoint examples, stable errors and golden fixture, and run their contract tests before implementation.
>
> Execute the plan in waves. For each implementation wave, spawn exactly three agents with the file ownership and acceptance criteria written in the plan. All agents share one checkout: they must not create worktrees, commit, deploy, revert or format another agent's files, or edit outside ownership. You own `api/src/index.js`, `app/lib/app/providers.dart`, navigation, dependency files, shared contracts and final integration. Require every agent to report changed files, exact tests/results, failures and risks; inspect every diff yourself.
>
> Complete Wave 1 export and its independent self-verification gate before starting Wave 2 restore. Implement same-account fresh-device restore, missing-row recovery, idempotent staged commit, local attachment/SMS restoration without re-ingestion, and full reconciliation. Preserve legacy reports and all external statement/SMS imports. Run the full API and Flutter suites, real PostgreSQL migration/RLS/role tests, large-account and adversarial archive tests, and the physical/emulated A-with-SMS to fresh-B-without-SMS drill. Treat skipped database/device gates as unresolved blockers. Continue until every completion criterion is verified or a concrete external blocker is recorded; do not declare success from mocks, partial suites or documentation claims.
