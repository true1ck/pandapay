# Offline-first portable backup and restore plan

Status: design proposal, 23 October 2026. This extends `portable-backup-export-import-plan.md`; it does not claim the current implementation works offline.

## Decision and guarantees

Keep one versioned, encrypted application archive with two declared modes. `local_only` works without a network and contains every account-owned row and file present on the source device, including durable pending mutations. It does **not** claim knowledge of server changes never downloaded. `converged` is made online after local writes are acknowledged and a server snapshot is included. Both modes can be imported offline into a fresh local namespace. A restore is `local_applied_pending_sync` until server reconciliation and a database-level comparison succeed; only then is it `converged`.

The archive must describe its scope precisely. A timestamp is informational, never the proof of synchronization. Stable row IDs, mutation IDs, a local applied-through server sequence, server high-water sequence, per-section count/byte length/SHA-256, and attachment digests are the proofs. Do not copy credentials, device ID, push token, biometric state, permissions, or SMS provider cursor.

## Findings in the current implementation

- `portable_snapshot.dart` requires every outbox drained before capture and has no pending-mutation section; offline export with unsent edits fails.
- `portable_restore.dart` requires a complete manifest; `portable_restore_finalize.dart` requires server commit before any local apply. Offline import is impossible.
- `portable_backup_models.dart` has a single `complete` flag without scope, section provenance, or a local sync watermark.
- `sync_queue.dart` stores `account_sync_state.last_server_seq`; the backup does not capture a safe checkpoint. `/sync/pull` filters out the calling device's changes, so a restored device must receive a new device ID and establish a fresh cursor.
- Local attachment enumeration occurs after row capture and may return an empty list on SQLite error. Local/server section names overlap. Restored-file checks do not verify the resulting database.
- The current Settings export uses legacy `/export`; keep its visual UI but route a distinct portable backup action through a coordinator. Statement/SMS file import remains a separate format.

## Ownership inventory and contract gate

Classify every local SQLite table, server table, and attachment source by account ownership and as authoritative, replicated, pending command, derived, device-only, or excluded with a reason. The coverage test must fail on new unclassified tables/columns. Include captured SMS envelopes/provenance, import decisions, review state, categories/tags, budgets, commitments, settings, attachments, and every durable outbox. Never assume `legacy` namespace belongs to the signed-in account; require a verified migration/binding. Use distinct paths such as `local/transactions.ndjson`, `server/transactions.ndjson`, and `pending/transactions.ndjson`; never merge them by name.

Create format v2 while retaining a read path for valid v1 archives. Manifest fields: format/schema version, archive ID, account binding, mode, snapshot time, local namespace identity, local applied-through server sequence, server snapshot high-water sequence (nullable), pending mutation IDs/counts, section provenance and hashes, attachment inventory, required capabilities, and explicit exclusions. `local_only` is complete for its declared local scope, not for the account. Reject unknown required capabilities, duplicate paths/IDs, missing files, bad hashes, cross-account references, and oversized input before mutation.

## Export algorithm

1. Resolve signed-in account and freeze a backup generation. Read all outbox counts; query errors fail closed. Create a consistent SQLite snapshot using the SQLite Online Backup API or a read transaction, and capture attachment metadata with it. Copy each referenced attachment to private staging and hash it; a missing file aborts. Stream rows in bounded batches; do not load an entire database or ZIP in memory.
2. **Offline:** include the durable pending command journal with original stable mutation IDs and ordering, plus the last *fully applied* server sequence. Mark mode `local_only`; never mark it converged. Do not discard or mark queued commands acknowledged.
3. **Online:** pause/serialize relevant local writes or record a generation fence. Drain and acknowledge outboxes, pull and apply through a chosen server high-water mark, then capture the local snapshot. Capture server rows in one PostgreSQL repeatable-read transaction at a recorded high-water mark. If the local and server watermarks cannot be proven compatible, retry or emit `local_only` with an honest scope. Handle concurrent writes through the generation fence, not wall-clock comparison.
4. Write a canonical manifest, self-read the staged archive, check counts/hashes/relationships, encrypt with authenticated encryption and a password KDF, fsync/atomically rename the final file, and clean private plaintext staging. An interruption leaves no successful archive.

## Import algorithm

1. Offline or online, decrypt and validate into private staging before modifying live state. Check account binding using a durable account identifier available offline; if identity cannot be established safely, stage only and require authentication before apply. Show declared scope and pending reconciliation in the existing flow.
2. Apply local authoritative records and pending commands to a **fresh** account namespace in one SQLite transaction. Verify the restored SQLite rows, relationships, totals, and attachment bytes against the manifest. Stage attachment file moves so rollback/retry cannot leave dangling metadata. Persist restore session, archive ID, phase, and checkpoint. Regenerate device identity and platform tokens.
3. If offline, stop at `local_applied_pending_sync`. The restored data is usable locally; never report a full clone. Resume automatically and idempotently on reconnect.
4. Online reconciliation: authenticate; fetch server state/high-water; preview conflicts by stable ID, version, ownership, and dependency. Replay pending mutations with original mutation IDs, **once**, in causal order. Never use last-write-wins for financial records or silently skip unique-key conflicts. Apply server recovery rows in foreign-key order, or through validated deferred constraints, in one transaction; require expected insert/compare counts. Pull changes to the new device from a fresh cursor; do not copy the old device's cursor. Rebuild derived projections and compare database-level counts, hashes, relationship checks, and monetary totals. Mark `converged` only after all comparisons pass.
5. Keep the durable session after an uncertain server response. Query status/ledger before retrying so economic events cannot be duplicated. Failure or conflict leaves local data and a repairable state, not a false success.

## Required scenario matrix

Test: empty and large account; online converged A→B; offline A export with pending edits and offline B import; A online but server changed concurrently; B offline then reconnect; two devices edit the same financial row; source SMS absent on B; missing/duplicate attachments; unowned legacy rows; wrong password/tamper/truncation; low disk; app kill at every phase; repeated import and uncertain commit response; server row deleted or changed after export; schema upgrades. Use a real PostgreSQL instance under application-role/RLS permissions and real SQLite files. Assert exact section counts/hashes, pending IDs, foreign keys, totals, and user-visible projections. A two-device drill is the release gate.

## Implementation order

1. Freeze inventory and v2 manifest/fixture; add coverage and scenario tests.
2. Build local-only export and offline staging/apply with durable checkpoint; prove A→B while both devices are offline.
3. Add server convergence with strict conflict handling, dependency ordering, and real PostgreSQL tests.
4. Add online converged export, generation fencing, bounded streaming, and crash recovery.
5. Connect the existing Settings actions without visual redesign; preserve CSV/PDF/JSON reports and external statement/SMS imports.
6. Run security, large-data, and two-device acceptance gates; only then label the feature complete and commit/push its implementation.

## Standards informing this design

- SQLite Online Backup API: https://www.sqlite.org/backup.html
- PostgreSQL Repeatable Read: https://www.postgresql.org/docs/current/transaction-iso.html
- Android offline-first data layer: https://developer.android.com/topic/architecture/data-layer/offline-first
- OWASP Cryptographic Storage: https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
