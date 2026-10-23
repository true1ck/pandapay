# Portable backup implementation status

Started 23 October 2026 by the parent integration task.

## Baseline

- Working directory: `C:\Users\sujay\CKProjects\PandaPay`
- Pre-existing modified files at start: `docs/portable-backup-export-import-plan.md`
- Pre-existing untracked path at start: `scratch/` (preserved; not part of this feature)
- No backup/restore implementation files existed before this wave.
- Contract owner: parent Luna integration task.
- Current wave: Wave 1 — complete export.

## Ownership

| Owner | Scope | Status |
| --- | --- | --- |
| Parent | Contract, `api/src/index.js`, providers/routes/dependencies, integration and final verification | Active |
| Agent A | `api/src/portable_backup/`, focused API tests, legacy CSV hardening/tests | Active |
| Agent B | `app/lib/data/portable_backup/`, focused archive/local snapshot tests | Active |
| Agent C | Export UI, independent inspector/fixtures and focused widget tests | Active |

## Gates

- [x] Investigation and implementation handoff written.
- [x] v1 policy fixed: same account, fresh target, online queue drain, encrypted complete archive, missing-row recovery, divergent-row conflict.
- [x] Contract artifacts and golden fixture reviewed (this wave rewrote the Wave-0 contract docs; golden fixture still pending — see gaps).
- [x] Wave 1 agent diffs inspected and integrated (encryption now real, routes mounted, coverage registry added).
- [x] Independent archive self-check passes (see commands below).
- [x] API and Flutter targeted tests pass (see commands below; full device gates remain open).
- [x] Wave 1 export route, coverage registry, archive crypto and focused tests are present.
- [x] Wave 2 restore staging/preview/commit routes, migration, local staging/finalization contracts, streamed HTTP export consumption and focused tests are present.
- [ ] Full device A/B export-and-restore drill and real PostgreSQL migration/RLS execution remain open.

## Verified this session (23 October 2026, Windows 11 / PowerShell 5.1)

Commands and results, run inside `C:\Users\sujay\CKProjects\PandaPay`:

| Command | Result |
| --- | --- |
| `cd app; flutter test test/data/portable_backup` | 31 tests, all pass (~8 s; Argon2id v1h/16384KiB dominates) |
| `cd app; flutter test test/features/import/portable_backup_inspector_test.dart` | 4 tests, all pass |
| `cd app; flutter analyze lib/data/portable_backup test/data/portable_backup` | No issues found |
| `cd api; node --test test/portable_backup_export.test.js` | 5 tests, all pass (144 ms) |
| `cd api; node --test test/portable_backup_coverage.test.js` | 3 tests, all pass (61 ms); inventory = 102 migration tables |
| `cd api; node --test test/portable_backup_export.test.js test/csv.test.js` | 16 tests, all pass (csv hardening re-verified) |
| `cd api; npm run check` | pass (`node --check` over 47 modules incl. index.js) |

Implemented in this session (Wave 1 scope, no UI changes):

- `app/lib/data/portable_backup/portable_crypto.dart`: real encryption replacing the stub encryptor — 68-byte v1 header, Argon2id (16384 KiB / 1 / 2 / 32), chunked XChaCha20-Poly1305 (64 KiB frames, 16-byte MAC), frame nonce `19 random + 5-byte BE counter`, frame AAD `header || 8-byte BE counter || final flag`. Decrypt maps wrong passphrase/tamper/truncate/trailing/magic/KDF mismatch to the typed errors above; `readPortableBackupArchive` returns the plaintext ZIP in staging.
- `app/lib/data/portable_backup/portable_archive.dart`: staged-file self-check now verifies the manifest digest of every file it writes; streaming `sha256Checksum` helper.
- `app/lib/data/portable_backup/canonical_ndjson.dart`: `PortableSha256Accumulator` moved to `package:crypto` chunked hashing after `package:cryptography`'s `Hash.toString()` proved non-hex (extra `64` prefix observed in digests).
- `app/lib/data/portable_backup/portable_snapshot.dart`, `portable_attachments.dart`: cancellation and digest plumbing fixes; fake-source ordering tests now assert call ordering (drain → sections → attachments) and pre-work cancellation.
- `app/pubspec.yaml`: added `cryptography ^2.9.0`.
- `api/src/index.js`: `registerPortableBackupRoutes(app, { requireAuth, pool })` mounted after `registerReferralRoutes(app)`; export route is live behind auth with the module's rate limit (3/min/IP).
- `api/src/portable_backup/coverage.json`: Wave-0 table registry — every one of the 102 migration tables classified (`exported_v1` 26 / `global_catalog` / `platform_ops` / `excluded_with_intent` with reasons).
- `api/test/portable_backup_coverage.test.js`: fails when a migration table is unclassified and when exported tables diverge from `PORTABLE_SECTIONS`.
- `docs/portable-backup-format-v1.md`: wire layout (header table + frame/AAD/nonce spec + failure semantics) appended under "Encryption envelope".

## Verified follow-up work (23 October 2026)

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
4. The client calls for the restore-session endpoints still need to be wired into the existing repository/service layer. The streamed export consumer is implemented; UI remains intentionally unchanged per the user's direction.
5. Golden fixture: `app/test/fixtures/portable_backup_fixture.dart` covers inspector shapes; a full end-to-end archive binary fixture suitable for all three inspectors is still open.

Agents must append exact commands, counts, failures and unresolved risks here when reporting. This file must not claim completion from mocked or skipped database/device gates.
