# PandaPay security implementation and database portability plan

Date: 22 October 2026. Reviewed source: `aca220a` on `master`.

Status: reviewed implementation plan. The work described below is not implemented or production verified by this document. Three Luna agents independently reviewed authentication, database recovery/portability, and mobile/console compatibility; the coordinator reconciled their findings against current source. No application tests, migrations, production calls, or data changes were run during this planning review.

Implementation has since started. Track implemented source, validation and remaining deployment gates in the [implementation progress record](security-implementation-progress-2026-10-22.md); this design document does not itself certify completion.

## 1. Requirements that every implementation must preserve

The owner has confirmed that **the application services and databases currently run on free hosting**. Future work must support moving the complete existing dataset to another host. These are persistent requirements for later agents, not optional infrastructure suggestions.

1. Implement the baseline using the existing services, PostgreSQL, standard encryption tools and the host's available scheduler. Do not require a paid database tier, KMS, Redis service, replica, Kubernetes deployment, or PITR subscription. Optional paid facilities may strengthen recovery later; they are not prerequisites for the baseline.
2. Preserve both logical databases: the product database and the separate auth database. The product database may be named `postgres` on a hosted provider and `pandapay` locally; discover names from configuration rather than hard-coding them. Preserve all application schemas, rows, identifiers, history, keys, relationships, jobs and migration records.
3. Preserve supported app/console behavior, including existing users, email login, enabled phone login, recovery, refresh, account switching, offline display, pending local writes, imports, financial calculations, sync and operator access. Unsafe authentication bypasses must be replaced with verified flows; their behavior is not a compatibility requirement.
4. **Confirmed by the owner: retain PostgreSQL and change hosting/provider only.** Migrate to a compatible PostgreSQL destination, preserving RLS, functions, enums, JSONB, extensions and their behavior. Select the destination provider through the capability and full-data restore checks in this plan.
5. Keep encryption and identity keys recoverable independently of the current server and database provider. A restored database must remain decryptable and searchable. Host migration must not silently generate replacement encryption, lookup, refresh, referral or signing keys.
6. Use additive schemas, compatibility readers, bounded resumable backfills and explicit completion checks. Do not wipe databases, recreate user IDs, merge accounts, reset device caches, or drop existing data as a shortcut.
7. Release only after fresh-install, existing-data upgrade, full restore, supported-client and host-move rehearsals pass. These are acceptance requirements, not a guarantee that an untested change cannot break the app.
8. Keep cleanup and data loss separate. Retention, deduplication and column retirement need a documented policy, reference mapping and reconciliation. An empty local table is not permission to delete a production table or its history.
9. **Owner decision, 23 October 2026: allow reuse of email/phone after account deletion.** Enforce contact uniqueness across non-deleted accounts, including unverified or disabled accounts that have not been deleted. Preserve deleted rows, original UUIDs and history; contact reuse does not relink a new account to the deleted account's data.
10. **Owner correction, 23 October 2026: preserve existing phone/email OTP recovery with no additional password or recovery-key prompt.** The earlier password-protected-export choice is superseded. Account access continues through the current verified phone/email flow. Recovery of receipts or unsynced records that exist only on a lost phone requires a separate prior backup; login alone cannot recover those bytes. Defer device encryption activation until that password-free data-recovery design is implemented and tested. Do not silently upload phone-only data or make a new credential a prerequisite for existing login.

The source audit remains useful evidence: [security audit, sections 8–9](security-and-backend-audit-2026-10-20.md) and [architecture review](architecture-data-review-2026-10-19.md). Their dates and local table/test counts must not be treated as current production facts. This document supersedes their proposed implementation order where they differ.

## 2. What exists today, and what the older review missed

These are source observations, not findings about the running production configuration.

| Area | Current source | Implementation consequence |
|---|---|---|
| Phone field encryption | `auth/src/utils/fieldEncryption.js` uses AES-256-GCM with a fresh IV. Invalid/missing keys or a disabled flag permit plaintext writes; decryption failure returns the original value. | Retain randomized authenticated encryption; enforce valid configuration and explicit legacy formats. A ciphertext authentication error must not be interpreted as plaintext. |
| Searchable phone encryption | `auth/src/utils/encryptedPhoneSearch.js` computes a keyed, canonicalized HMAC. Routes/OTP writes already use `phone_lookup_hash`. | Preserve the existing key and normalization semantics during migration. Add reviewed lifecycle uniqueness and future key versioning. |
| Existing-data backfill | **A backfill exists** in `auth/scripts/migrate.js:13`, called at line 72. It selects all missing rows into memory and updates them individually. | The earlier statement that no backfill exists was incorrect. Make this implementation bounded and connect it to actual deployments. |
| Production migration path | `deploy/deploy.sh:197` starts Compose `db-migrate`; `docker-compose.prod.yml:36` runs the DB image; `db/scripts/migrate.sh:81` applies auth SQL directly and records its ledger. It does not run the JS backfill or receive its encryption/HMAC configuration. | Schema can be marked applied while existing phone hashes remain absent. One authoritative deployment flow must run and verify required data work. |
| Empty auth database | `auth/db/pandapay-auth/init.sql` defines base tables, while the auth migration directory begins with `ALTER TABLE users`. Local container initialization is a separate path. | Establish a verified empty-install baseline; applying incremental auth DDL alone is insufficient on an empty destination. |
| Identity/session fixes since audit | Supported signup/linking guards, conditional OTP consumption and `crypto.randomInt` are present. `api/src/auth.js` calls current-session verification; `currentSessionVerification.js` checks lifecycle/device/token version. | Revalidate these changes and their races rather than recreating old fixes. The product verification cache currently has a five-second TTL; publish and test this revocation bound. |
| Remaining identity gaps | Contact indexes are not unique; phone normalization differs across helpers; OTP purpose is not durably bound to the SQL challenge. Public legacy/debug paths and logging still need consumer and exposure review. | Resolve uniqueness and purpose binding with migration and client compatibility, not comments or SELECT-before-INSERT checks. |
| Transport | API and auth pools still use `rejectUnauthorized: false` when DB TLS is enabled. | Configure verified trust in every connection path, including SSM, migration and backup tools. |
| Backup | `db/scripts/backup.sh` and the predeploy dump accept the product URL only. Compose saves scheduled dumps to a local named volume. Compression and listing the archive do not encrypt it or prove a complete recovery. | Add auth coverage, source-side encryption, independent off-host copies and an actual restore gate. |
| Privileges and scheduling | `db/setup_app_role.sql` still has broad table/function grants. `db/scripts/migrate.sh` skips `0013_cron_jobs.sql`. | Define reviewed per-role grants and install monitored portable jobs instead of assuming provider cron works. |
| Device data | `app/lib/data/local/app_database.dart` opens plain SQLite with WAL and upgrade logic. It stores private cached data and durable pending work. Receipts are private local files. Android backup is disabled. | A server move cannot migrate device-only records. Any device encryption upgrade must preserve the database, outboxes, namespaces, WAL and local files. |
| Console | Email and phone OTP login both exist in the current login screen, unlike the dated phone-only finding. Tokens still persist in SharedPreferences/browser storage. | Preserve email operator login; plan a separately tested browser session transition. |
| New workers/features | Referral/rewards outbox, SMS/AI tables and workers have been added since the audit. | Inventory the whole checkout and deployed schema; never limit exports to the audit's old list of 96 tables. |

Completion labels used during implementation: `source present`, `test verified`, `deployment verified`, `open`, `partial`, or `not applicable with evidence`. Source presence alone does not close a finding. Record commit, configuration/migration version, test result and deployed check for each closed item.

## 3. Encryption design and recovery boundaries

### 3.1 What each layer protects

| Layer | Required baseline | Compatibility and limits |
|---|---|---|
| Public and internal transport | Verified HTTPS at ingress; verified DB TLS; private authenticated API-to-auth traffic. Plain HTTP between local containers is allowed only on an explicitly isolated host network. Cross-host internal traffic needs verified TLS. | Keep current API/auth domains stable during rehosting. Trust roots/hostnames belong in configuration, not baked into app data. |
| Database disks | Inspect and record whether the current free provider encrypts its disks/snapshots and whether customer configuration is needed. Do the same for a destination. | This cannot be proven from the repo. For self-hosted disks use supported volume encryption. If the provider cannot supply it, record the unresolved gap and select a compatible deployment before claiming full database encryption at rest. Do not invent a free-tier guarantee. |
| Server field encryption | Preserve auth phone encryption and protect IMAP credentials; add explicit formats/key IDs, safe error behavior and targeted coverage based on the field inventory below. | Keys remain outside DB dumps. Server application access still permits intended decryption; field encryption does not make a compromised application host unable to read its own data. |
| Backups and exports | Encrypt before upload using a portable tool, proposed `age` with a recovery recipient; require verified off-host recovery. | Keep recovery private keys outside the production server. DB dumps contain ciphertext but also other private financial data, so the entire export must be encrypted. |
| Device database and receipts | Stage an encrypted SQLite/file upgrade using platform-backed key custody and verified copy/swap recovery. | Device keys are not server DB keys. Local-only files/unsynced records remain on the device; do not introduce silent cloud uploads or destructive recovery. |

Before expanding field encryption, inventory every persistence copy: auth contact fields, product `profiles` contact mirrors, OTP requests, recovery data, IMAP connection metadata, raw mail/SMS/import payloads, audit/log fields, exports, browser storage, device snapshots and receipts. Classify which columns need equality search, range/aggregate queries, joins or only retrieval.

Required decisions: encrypt normalized contact values and sensitive retained raw payloads where the server needs recoverable content; pair encrypted identity lookups with separately keyed blind indexes. Minimize raw payload retention where the feature does not require it. Preserve exact money values, canonical financial rows and their SQL query/constraint behavior; whole-row application encryption is not an acceptable shortcut for the current relational model. Full database disk protection and least privilege still apply to financial tables. Email/profile encryption is a separate additive migration after the phone path is stable; do not send ciphertext to existing clients or accidentally leave plaintext mirror columns unaccounted for. OTP codes and refresh tokens keep appropriate one-way verification storage rather than reversible encryption for convenience.

### 3.2 Portable key inventory

| Key or configuration | What must survive a move | Rotation rule |
|---|---|---|
| Existing `ENCRYPTION_KEY` | Exact bytes needed for legacy phone ciphertext; retain its format/version metadata. | First deploy readers that decrypt old formats and write a versioned new format; re-encrypt in verified batches before retiring an old key. |
| `PHONE_LOOKUP_HMAC_KEY` | Exact existing bytes, canonicalization version and blind-index values. | Maintain separate v1/v2 slots; compute both during migration, backfill v2, check conflicts and switch reads. Never overwrite the sole active key and invalidate all lookups. |
| `SMS_LEARNING_HMAC_KEY` | Exact bytes and sender-normalization/version semantics used for persisted SMS sender fingerprints. | Keep stable during rehosting. Rotation requires versioned fingerprints, reindexing and reconciliation against historical learning rows. Mark not applicable only with evidence that no retained data depends on it, not merely because the worker is currently disabled. |
| `IMAP_ENCRYPTION_KEY` | Existing pgcrypto-encrypted credentials and extension compatibility. | Retain legacy decryption during any envelope transition. Encrypt new credentials in application code so future encryption keys need not travel as SQL parameters. Verify bytea export/restore and provider login without logging secrets. |
| Access JWT key ring, active key ID, issuer/audience | Preserve existing valid access sessions during rehosting. | Coordinate auth/API verification sets. Retain prior access verification keys for their token lifetime plus skew and the supported rollback window. |
| Refresh JWT secret and rotation state | Existing refresh tokens, hashes, rotation-family links, device IDs, revocations and retry/recovery semantics. | A single-secret replacement currently invalidates or changes refresh behavior. Add explicit multi-key support first if rotating; a host move alone must not rotate it. |
| Referral identity HMAC/version, engagement/preview/worker/internal-service/webhook secrets | Maintain identity and dedupe semantics; retain integration authentication. | Distinguish data-derived HMACs from transport-only credentials. Reindex data-derived values if rotating; coordinate verification overlap for transport credentials. |
| TLS CA, provider OAuth configuration and mobile signing keys | Trust valid endpoints; retain existing app install and OAuth identities. | Restore through the appropriate secret/config channel; never store these in Flutter compile-time constants or exported customer rows. |
| Backup recovery recipients/private keys | Recover all retained encrypted exports, including versions made before rotation. | Production holds encryption recipients, not the only recovery private key. Keep an independently recoverable second copy of recovery material. |

Use cryptographically random, separate per-purpose keys, restrictive file/secret permissions and documented key IDs. The free baseline may use protected host secret files plus separately controlled encrypted recovery escrow; a vendor KMS is optional. Include an encrypted key/config recovery package and runbook, stored separately from data backups and never as a raw `.env` copied into the dump. A recovery operator must demonstrate restoring keys as well as records.

Versioned application ciphertext should identify algorithm/format and key ID, use a fresh nonce, retain an authentication tag and bind stable field/record context as authenticated data where appropriate. Do not bind hostnames or database connection names into encryption context; moving hosts must not invalidate it. Explicitly distinguish recognized legacy plaintext from legacy ciphertext. Unknown versions, wrong keys and failed authentication produce controlled errors and a repair report, never a new plaintext write, empty dataset, automatic key generation or silent data discard.

## 4. Delivery phases and release gates

Every phase yields a small reviewable change with source, migration/config updates, relevant tests and rollback notes. Keep schema-changing deployments and key-changing deployments separate. Run against disposable databases with synthetic fixtures in CI; use restricted isolated restore environments for real-data recovery exercises. Dumps, contacts, tokens, decrypted messages and keys never become CI artifacts, logs or Git files.

### P0 — Establish the actual baseline

Owner: coordinator with all six work packages. Dependencies: none.

- Record deployed commit/image digest, supported mobile/console versions, both DB versions/names/encoding/collation, migration ledgers/checksums, schemas/extensions, actual roles, provider limits, storage/egress/connection budgets and current jobs. Do not infer these from local metadata or example URLs.
- Inventory all tables/sequences/views/functions/triggers/RLS policies/default privileges, including recent referral/rewards/SMS/AI data. Record which application-owned objects exist outside `public` and which objects the provider owns.
- Record auth-to-product UUID relationships (`profiles.id`/admin membership and auth users), full data counts, duplicate/invalid contacts, undecryptable rows and orphan relationships using restricted reports. Do not print contact values.
- Freeze the API/error/token contract and capture synthetic behavior fixtures for current/oldest supported clients. Preserve route/public/admin boundaries and record consumers of signup, guest, check-user, validate-token and Google login before changing them.
- Identify data that exists only on devices, external provider/object references, pending imports/outboxes/deletions and current free-host sleep/scheduler behavior.
- Inventory current key purposes and verify recoverability using a synthetic canary or restricted sample; collect evidence, not secret values.

Gate: signed-off manifest of the actual deployment and compatibility fixtures. Unknown provider capabilities remain visible action items. No bulk transformation starts before recovery is demonstrated in P1.

Immediate containment lane: once a supported replacement flow and a focused regression check exist, ship fixes for any still-reachable identity bypass or OTP/secret logging without waiting for a full encryption rollout. Use current code evidence: several S01/S02/S06 changes are already present. Keep containment active through every later rollback.

### P1 — Recovery, verified transport and portable migration machinery

Owners: Luna 1 and Luna 3, integrated sequentially where files overlap. Dependencies: P0.

**Migration runner (`db/scripts/migrate.sh`, `auth/scripts/migrate.js`, Compose migration service):**

1. Choose one authoritative orchestration path that executes the product and auth schema steps and explicit data jobs. Reuse corrected JS backfill logic through a dedicated migration CLI/job; do not give long-running services migration privileges. The migration job receives the required keys securely and only for the operation.
2. Create/verify an empty-install auth baseline and an existing-schema upgrade path. Validate exact schema before recognizing a historical baseline; never mark migrations applied because a table merely exists. Restore uses full schema archives into empty DBs, not bootstrap plus the same schema dump.
3. Maintain independent ledgers with filename/version and checksum. Use a database advisory lock on a dedicated connection; coordinate the product/auth sequence with one orchestrator because two databases cannot share a SQL transaction. Retry safely after one side succeeds.
4. Use per-migration transactions where valid; treat concurrent index creation as a distinct nontransactional job with explicit completion/invalid-index recovery. Use lock/statement timeouts and fail on partial or mismatched checksums. Preserve applied historical filenames; resolve duplicate prefixes for future migrations without rerunning renamed old files.
5. Separate privileged migration URLs from API/auth runtime URLs. Add a future `AUTH_MIGRATION_DATABASE_URL` rather than reusing a limited `AUTH_DATABASE_URL`. Make grants reproducible on an empty destination and after a restore.

**Transport (`api/src/db.js`, `auth/src/db.js`, connection config, migration/backup clients):** configure CA/system trust, hostname verification and explicit local-only non-TLS mode. Test every initialization path. Resolve connection-string SSL parameters consistently so they cannot replace the intended trust configuration. Exercise trusted, untrusted, expired and hostname-mismatched certificates before enforcing production settings. Stage the correct trust bundle first to avoid cutting off a valid hosted DB.

**Backup (`db/scripts/backup.sh`, `restore_drill.sh`, `deploy/deploy.sh`, backup Compose service):** implement the recovery design in section 5. Predeploy backups must cover auth before auth data/schema changes and produce a paired set when changes cross databases.

Gate: empty-install and upgrade converge; actual Compose deployment invokes required backfills; wrong/missing keys stop affected migration; runtime cannot change the ledgers; both DBs are restored and decrypted on another machine; real-role app checks pass. Rollback changes service configuration/code to a compatible secure release; it does not erase applied additive schema or restore stale data over accepted writes.

### P2 — Portable encryption and safe identity migration

Owners: Luna 2 with Luna 1 reviewing every auth migration. Dependencies: P1. Identity containment remains active.

1. Unify canonical phone handling and document the existing India default, explicit E.164 values, malformed legacy rows and normalized email handling. The owner chose contact reuse after deletion: indexes and every availability/claim lookup must use the same non-deleted-account scope. A canonicalization change is a data migration, not a helper cleanup.
2. Introduce explicit encryption format/key metadata and validated key rings without changing existing key bytes. Keep the current phone ciphertext format/key unchanged throughout a pure host move. For a separate format transition, add a nullable `phone_number_v2` column or equivalent parallel storage first. Deploy a secure bridge release that understands both formats to all auth/API/worker/migration readers, initially writing the existing format. Then enable transactional dual writes, backfill/verify v2 and switch authoritative reads. Fence all v1-only writers before v2 becomes authoritative. The rollback target must be this secure compatible bridge release, with dual writes preserved; a pre-bridge binary that can emit envelopes as plaintext or leave v2 stale is forbidden. Retire old writes/storage only after the compatibility/rollback window. Require valid encryption in production and fail initialization before taking traffic on invalid configuration.
3. Repair deployment orchestration for phone hashes. Replace full-table SELECT with bounded keyset batches, proposed initial maximum 100 rows with one worker, checkpoint/progress counters and safe restart. Tune from measured free-host memory/latency. Conditional updates must detect a contact changed after selection; never attach an old phone hash to a newly changed contact.
4. Run dry-run conflict/decrypt checks first. Backfill from valid legacy plaintext or successfully authenticated plaintext recovery; preserve original rows. Quarantine unresolved/ambiguous identities for verified resolution and retain a recovery mapping. Do not turn inability to decrypt into a blank field or silently skip it and mark complete.
5. Require dual writes of ciphertext, index and metadata within the same transaction while compatible readers remain available. Do not introduce decrypt-every-row query fallbacks or deterministic AES/GCM to repair search.
6. After backfill, verify every in-scope phone row/index, not just a sample. Independently recompute blind indexes in bounded verification batches. Define null cases explicitly. New/updated rows must be protected from creating duplicates while the unique index is built; use transactional locking/serialization appropriate to the normalized identity until DB uniqueness is enforced. Recheck immediately before activation.
7. Create reviewed unique normalized-email and phone-blind-index constraints for the chosen lifecycle. Partial unique indexes remain indexes where PostgreSQL cannot attach them as an ordinary unique constraint. Handle uniqueness violations as transactional conflicts and test concurrent signup, linking, recovery, contact changes and deletion/reuse.
8. Apply the same additive pattern to approved email/profile contact mirrors and sensitive retained raw payloads after phone stabilization. Keep existing API plaintext field semantics for authorized callers; migrate all internal queries and indexes before stopping old storage writes. Include OTP/recovery records and all persisted copies from the inventory.
9. Move IMAP secret encryption behind a versioned application encryption adapter with legacy pgcrypto readers. Use a parallel v2 ciphertext column, compatible bridge release and transactional dual writes; do not place new envelopes into a column a rollback poller will pass to `pgp_sym_decrypt`. Backfill/verify existing bytea records in bounded owner-safe operations, fence old-only credential writers, then switch pollers/tests. Keep extension and key support until retained legacy backups no longer require them.

Gate: no unexplained rows, no active identity conflicts, no plaintext downgrade, randomized ciphertext for equal values, complete index verification, positive/negative decrypt tests, transaction races safe, supported old/new clients pass, and both DBs plus retained old/new keys survive a different-host restore. Keep legacy columns until P7. Key rotation is tested as a separate operation and is not bundled with rehosting.

### P3 — Complete authentication, sessions and browser security

Owner: Luna 2; console client changes coordinated with Luna 5. Dependencies: P2 for identity constraints, P1 for recovery; stateless containment/logging fixes can ship earlier.

- Revalidate S01/S02 identity proof and subject-bound signup/linking against the current code. Move contact lookup/claim/uniqueness changes into atomic operations; existing and new contacts each need appropriate proof. Preserve supported email-only onboarding and recovery.
- Bind each OTP durably to challenge ID, contact, subject where known, purpose, expiry and consumption state. Recovery, linking and sign-in challenges cannot substitute for each other. Compare and consume conditionally, with atomic attempts and safe valid/invalid races.
- Keep secure randomness. The present four-digit format remains until a compatible client transition is demonstrated. If moving to six digits, first ship client support for advertised length/challenge identity and maintain a bounded legacy route/format window. Do not change only the generator and lock out released clients.
- Verify current-session checks in API, ordinary auth middleware, refresh and legacy validation paths. Preserve `503 unavailable` versus `401 invalid`; never clear local data or report logout because the auth service sleeps or is unavailable. Define the five-second verification-cache bound and avoid caching an outage as a valid session.
- Reject anonymous/guest/inactive/deleted/revoked/wrong-device access consistently. Preserve local guest mode and inventory consumers before retiring server guest/debug/check-user routes. Account-existence responses are uniform and abuse controlled.
- Implement trusted-proxy configuration for the real ingress topology. Ingress replaces untrusted forwarding headers; direct upstream access is blocked. Add shared durable attempt/challenge budgets using the existing authoritative database if a shared Redis service is unavailable. An in-memory limiter alone does not survive a restart or support multiple replicas. Redis remains optional, with conservative outage behavior if selected.
- Replace verbose token/contact/query logging with allowlisted structured events and masked metadata in both services, providers and DB logging. Fix the DB logger circular dependency before enabling it; query values and decrypted data are excluded by default.
- Move console sessions to a same-origin HttpOnly/Secure/SameSite cookie/BFF flow with CSRF/Origin controls and CSP. Stage browser API/config and console together; keep mobile Bearer auth intact. Define a bounded transition for already-open/cached console bundles: temporarily accept their existing verified Bearer transport under the same admin/session checks while the new console uses cookies, then require a versioned reload and fresh sign-in before retiring the old transport/storage. Publish the supported minimum console version and retirement condition; never silently strand a cached bundle. Test email operator login, renewal, logout and non-admin denial before removing legacy browser-token persistence. CSRF/Origin checks apply to cookie-authenticated requests throughout overlap.

Gate: supported login/recovery/refresh work before and after restart/restore; exactly one OTP consume wins; wrong-purpose and replay tests fail securely; revocation meets its declared bound; auth unavailability preserves offline data; no synthetic secrets reach logs; current/oldest clients and console pass.

### P4 — Least privilege, integrations, durable jobs and account lifecycle

Owners: Luna 1, Luna 3 and Luna 4 with one owner for each shared file. Dependencies: P1–P3 as applicable.

- Introduce separately scoped auth runtime, API, migration/owner, backup/read and worker roles. Audit `PUBLIC`, inherited/default privileges and every SECURITY DEFINER function, fixing safe `search_path`, owner, object references and allowed execution. Verify owner RLS using actual non-superuser/non-bypass runtime connections. Ordinary roles cannot mutate migration metadata or assume worker authority.
- Fix IMAP worker enumeration under RLS using a narrow worker operation; hold acquisition/work/unlock on one session or use durable transaction-scoped leases appropriate to processing. Enforce host/port/provider policy on save, test and every poll, including resolved IPv4/IPv6 destinations and DNS rebinding. Bound timeouts, socket counts and mailbox work.
- Validate lounge card ownership and benefit/product relationships atomically. Repair partner callbacks with scoped permissions and durable provider-event dedupe. Return sanitized backup health without exposing file paths or private errors.
- Resolve Google-account-login support separately from Gmail import; choose one tested provider-link representation. Revalidate the auth dashboard/role model and production debug assets. Preserve currently working console email sign-in.
- Inventory every job in skipped `0013_cron_jobs.sql` and every current rewards/AI/import/notification worker. Install required portable scheduled jobs with locking/leases, bounded work, idempotency, retries, heartbeats and alerts. On a sleeping free host, use an authorized external wake-up/scheduler or document when execution will resume; process presence is not evidence of timely deletion or recovery.
- Implement an idempotent two-database deletion workflow with durable step state, retry after either-side failure, session revocation, import/attachment handling and deletion evidence. Define and test the existing grace period. Future restores must reapply completed deletion/revocation events before reopening traffic. Preserve only the metadata necessary to enforce the policy.
- Define retention for OTP/refresh/audit/raw import records and cursor/change logs. Preserve refresh replay detection and long-offline sync recovery; do not prune records required by supported devices. Retention is enabled only against the documented policy and verified data categories.
- Reuse existing outboxes/leases where correct; add durable delivery for important events missing an outbox. Drain or persist in-flight work during rollout. Do not assume a new queue creates an atomic DB-write-plus-send transaction.
- Bound pool totals and expensive work across API, auth, rewards/AI workers, backups and migration jobs. Add provider quotas/timeouts and backpressure while keeping sign-in and small financial writes usable. Keep operator permissions and high-impact action verification explicit.

Gate: real-role cross-user tests, worker restart/duplicate delivery, deletion partial-failure recovery, retention/cursor safety, integration/provider failure and free-host exhaustion tests pass. Rollback keeps needed worker ownership/grants and durable progress; pending work is not lost or replayed for duplicate financial effects.

### P5 — Device and app compatibility hardening

Owner: Luna 5. Dependencies: P0 contracts; server/console changes from P3/P4 where required. Device encryption is released separately from the server data transformation and host migration.

1. Retain secure-token migration from legacy SharedPreferences and account-based cache namespaces. Preserve local guest data and explicit guest-to-account migration choices; never assign guest SMS to the next user automatically.
2. Select a maintained encrypted SQLite implementation compatible with Flutter/native builds and the present SQL features. Prototype with synthetic databases first. Generate a random local database key under platform-backed custody; verify supported Android/iOS behavior and web limitations before committing to a package.
3. Close/quiesce all DB writers and queue listeners; checkpoint SQLite WAL through SQLite APIs. Account for the main DB, WAL and shared-memory files. Check temporary disk space before copying; do not start a copy the device cannot finish.
4. Copy the entire database into a new encrypted file with resumable migration state. Verify schema, every table's data, account/guest namespaces, pending queues, cursor/device state, tags, local cards and attachment references. Flush files and use an atomic switch with crash recovery. Never treat a decrypt/open error as a fresh install.
5. Keep a protected rollback copy only for a short explicit migration window. After new writes begin, any fallback must preserve them through a tested export/replay path; opening the old plaintext copy would lose those writes. Clean up the old DB/WAL/temp files after verified successful launches and recovery checks. Do not promise secure erasure of flash blocks; rely on platform and file encryption protections.
6. Encrypt receipt/bill files by verified copy plus atomic metadata/path update; preserve originals until the new copy is confirmed. Keep receipts local and leave source gallery files untouched. Add bounded cleanup for abandoned app-owned OCR temp files and interrupted preparation.
7. Define key-unavailable/key-loss outcomes explicitly. Before the encrypted switch, failed key provisioning leaves the existing database intact and usable. After activation, a permanently lost nonexportable key cannot decrypt its ciphertext: preserve files and show a recovery state instead of initializing an empty DB, and do not claim readable recovery without a tested recovery key/export. Platform keys may not transfer to another phone. Before enabling encryption for irreplaceable local-only outboxes/receipts, establish the approved device-loss policy and deliver a tested recoverable key/export mechanism if such loss must be recoverable. A PostgreSQL migration cannot supply that local data or key recovery.
8. Preserve Android `allowBackup=false`, on-device read-only Gmail authorization, current permission flows, offline snapshots on transient failures, sign-out/account-switch queue semantics and sync idempotency. Server IDs and sync ordering survive rehosting. Any cursor/history reset uses a tested full-resync protocol that retains unsent mutations.
9. Verify signed release networking, signing compatibility, dependency/native behavior and the documented shrinking/Room paths on actual devices. Review stronger binary/pinning controls only with a recovery/rotation design; they do not replace server authorization.

Gate: fresh/upgrade/current-oldest client matrix, migration interruption, low disk, offline startup, pending SMS/manual edits, receipts, account switching, sign-out/relogin and guest mode preserve existing readable data when keys remain available. Key provisioning failure before the switch preserves the usable legacy DB. Wrong/unavailable keys after activation preserve ciphertext and refuse destructive reinitialization; permanent key loss is recoverable only through the separately tested recovery mechanism. Resolve that device-loss policy before enabling encryption. An old mobile binary that cannot open encrypted storage is not a valid rollback; provide a forward repair build and tested recovery tool.

### P6 — Full database move rehearsal and release verification

Owner: Luna 6 with coordinator. Dependencies: all changes in the release candidate plus P1 recovery. Use the cutover procedure in section 6 on a separate PostgreSQL instance/host.

Exercise the complete current dataset through export, key/config recovery, restore, grants, jobs, functional reconciliation and old-client compatibility. Test host failure, provider sleep/quota, partial uploads, missing extension, wrong CA/key, interrupted backfill, target write then rollback request, and replay of pending import/outbox tasks. Record measured duration, disk/connection/memory usage and recovery point. Fix discrepancies and repeat the affected path; do not certify release from the old audit's test counts.

Gate: section 7 passes, with a signed checklist and restore/cutover evidence attached to the reviewed release commit. Production deployment is a separate release action after these concrete results exist.

### P7 — Retire compatibility storage and close documentation

Owner: coordinator with data/client owners. Dependencies: monitored rollout, complete reconciliation, tested recovery and expired compatibility/rollback windows.

Stop legacy writes, verify every applicable row is converted, then retire old columns/ciphertext readers or keys through a new reviewed migration. Historical encrypted backups remain recoverable until their retention expires; removing a live key is not permission to destroy a retained backup's only decryptor. Remove any short-lived plaintext backup columns/files and ensure WAL/replica/snapshot/backup retention matches the stated policy.

Perform D01–D05 dedupe/index changes only when equivalence, dependent references and before/after financial totals are proven; retain ID mappings and distinguish duplicated state from additive spend. Do not drop C01/C02/C05/C06 items solely because they look unused. Refactor the API only in independently verified changes preserving its route/guard contract. Update deployment, privacy/security claims and architecture wording to match demonstrated behavior.

## 5. Portable backup and full-data recovery specification

### Backup set contents

Each set has one backup ID and an encrypted detailed manifest containing:

- Complete schema/data/sequence/large-object exports of both logical databases and all application-owned schemas. Do not restrict to the dated audit's table names or omit historical/unused-looking rows. Record exact start/end times and whether writes were quiesced.
- DB/server/client versions, encoding/collation, extension versions/schema locations, application commit/image digests, migration ledgers/checksums and job definitions.
- Reviewed role/ownership/ACL/default-privilege definitions and provider mapping. Managed service roles/tablespaces are not blindly recreated. Where the provider denies cluster-role exports, generate equivalent application-role bootstrap scripts and a verifiable grants manifest.
- Reconciliation counts, canonical aggregate digests and financial invariants, auth/product identity relationships, pending outbox/job checkpoints, sequence and sync high-water marks, deletion/revocation journal boundary.
- External object manifest/content if present and application configuration dependencies. Device-only receipts, Google/on-device data and unsynced queues are separately classified and must never be claimed as included in a server dump.
- Optional external Redis/security-store state: active challenge bindings, attempt/rate budgets and expiry semantics are security state, not disposable public-response cache. Export/restore it safely or use a rehearsed conservative transition that invalidates transient challenges and retains/reconstructs abuse budgets without extending TTLs or resetting protections. Document any deliberate requirement to request a fresh OTP after maintenance. Rebuild only genuinely disposable caches.
- Key IDs/format versions and the reference to separately controlled key recovery material. Secret bytes do not go into the database manifest.

Use PostgreSQL custom-format logical archives for portability. The export client must support the source major version; the rehearsal uses matching tooling and a same-major target first. A newer compatible target requires its own restore test; restoring to an older major is not assumed. Build roles/extensions appropriately, restore the schema/data and then verify ownership/ACLs. Because current scripts use `--no-owner --no-privileges`, a data restore without explicit grants is incomplete. PostgreSQL documents that a dump covers one database; globals need separate treatment. [PostgreSQL pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html), [pg_dumpall](https://www.postgresql.org/docs/current/app-pg-dumpall.html), [pg_restore](https://www.postgresql.org/docs/current/app-pgrestore.html).

### Creation, copies and consistency

Proposed free baseline: stream archives through `age` to an encrypted `.part` object using pipefail and restrictive temporary-file permissions; finalize only after every process exits successfully. Upload ciphertext with a checksum, download/verify it at the recovery destination, and atomically mark the set complete. The server needs only an encryption recipient; actual decrypt/restore drills run on a separately controlled recovery machine. Never label an incomplete/auth-missing/upload-only set as restore verified. [age project documentation](https://github.com/FiloSottile/age).

Maintain two encrypted off-host copies across independent failure domains, using existing owner-controlled storage or a suitable free allowance after verifying capacity and terms. One can be a protected recovery computer/offline disk rather than another cloud subscription. A sleeping laptop that has not received recent copies is not a current backup. Do not count a Docker named volume as off-host. If two current copies cannot fit the available free resources, record that unmet gate and change retention/destination/cadence with the owner; never silently stop protection or delete the last good set.

Owner decision during implementation: until the live VM is identified, the
initial recovery location is the owner's Mac in
`/Users/chandresh_kerkar/Documents/PandaPay-Recovery`. This is explicitly one
local encrypted copy with a `local_saved` status. The initial daily policy is
seven generations / seven days, 1 GiB archive cap, preserving recent/proven
sets and stopping when protected sets cannot fit. The Mac reserves 5 GiB free
and stops at 95% disk use; server defaults reserve 512 MiB and stop at 85%.
The daily 07:45 local schedule remains inactive until actual source URLs are
confirmed. Provisioning two independent copies and proving actual recovery
remain requirements before the production rollout gate is closed.

For ordinary scheduled backups, each DB dump is consistent independently; two concurrent dumps are **not automatically a consistent cross-database snapshot**. Choose either a brief coordinated write barrier, or record/replay a tested cross-database provisioning/deletion reconciliation journal. Do not hold nightly login writes for an unmeasured duration. The final planned host cutover always uses a write freeze unless separately proven change replication is available.

Initial proposed objectives: complete a daily paired backup with both off-host copies, alert once its age exceeds 26 hours, and retain at least two complete restore-verified generations plus measured retention within quota. The daily schedule has a potential disaster loss window of up to one backup interval; it cannot promise zero loss. Set the recovery-time objective from actual rehearsals. For a planned migration, require **zero acknowledged-write loss** through the final barrier. Adjust objectives/cadence explicitly if product needs exceed free-host limits. Managed PITR can be added later but does not replace a portable logical restore test.

Record upload and restore results separately. Prune only complete sets after a later known-good set exists at both destinations; retain required key versions. Alert on missing auth archives, partial upload, decryption/restore failure, unusual size/count, failed retention, storage pressure and expired credentials. Test an actual operator notification before relying on it; notification recipients are configured by the owner.

## 6. Future host migration and cutover procedure

### A. Capability and destination preflight

Verify supported PostgreSQL version, encodings/collations, `uuid-ossp`/`pgcrypto` and every actual extension, extension schemas/search paths, PL/pgSQL/enums/JSONB/RLS/functions/triggers, role/grant capabilities, verified TLS, direct versus pooled connections, storage/headroom and connection quotas. Recheck optional scheduler/provider dependencies rather than assuming Supabase/AWS facilities exist elsewhere. If a provider permits only one DB, use two suitable endpoints/projects or commission a separate reviewed isolation redesign; do not combine auth/product public schemas ad hoc.

Keep API/auth domains stable if possible; change backend connection/configuration behind them. Inventory OAuth authorized origins/redirects, mobile package/signing identity, mail forwarding/DNS, inbound webhooks, Firebase/notification integration, callback URLs and IP allowlists. Carry their IDs/configuration forward. Keep secrets portable in secure configuration and avoid dependence on current host paths or provider-specific encryption.

Provision the new host with the same compatible application release first. Do not mix rehosting, PostgreSQL major upgrade, key rotation and a new financial schema in one cutover. Warm readiness and measure free-tier cold starts. Restore into empty isolated destination DBs, reapply reviewed roles and trust config, and keep all external-effect workers/mail sending disabled during rehearsal.

### B. Rehearse and reconcile

Restore both full archives and necessary external objects/key material. Reconcile **all** application tables and keys with deterministic canonical per-table/chunk digests, row counts and object inventories; use explicit ordering/types and distinguish ciphertext bytes from decrypted-value checks. Store sensitive digests/reports in restricted encrypted evidence. Counts alone are insufficient.

Validate auth user/product profile/admin mappings, foreign keys/orphans, sequences greater than existing IDs, contact hashes and decryptability, sessions/devices/revocation families, sync cursors/change logs/conflict history, financial totals by user/currency/period, caps/benefits/rewards/referral ledger, custom categories/tags, raw source provenance/idempotency/dedupe and pending imports/outboxes/deletions. Preserve tombstones, UUIDs, exact decimal/integer units, timestamps/timezones, JSON and bytea formats. Reapply role/RLS/function/job checks and run supported client flows. Keep calculated/derived state until parity is proven; do not regenerate it and discard original evidence.

For very large data, use bounded ordered chunks and record the verified range; do not sample away whole tables. Destination-only test rows are clearly identified and removed before real reconciliation. Apply outstanding valid deletion/revocation events before exposing restored data.

### C. Final switch with zero planned write loss

1. Announce the measured maintenance interval, freeze CI deploys and capture source/target key/config/image versions. Take a preliminary backup ahead of the window to measure time.
2. Activate a server write barrier that covers **both** databases: financial writes, auth login/OTP/refresh/contact changes, sync pushes, webhooks, administrative writes and every rewards/AI/import/IMAP/deletion/notification worker. Include any external security-state store in the barrier/recovery procedure; do not reset attempt budgets or reactivate consumed challenges during a move. Put in-flight work in a known durable state. Drain or cancel safely, check no remaining writers and reject writes explicitly/retryably. GETs that mutate data count as writers. An HTTP maintenance banner alone is insufficient.
3. Keep local mobile edits queued using existing offline behavior. Reject provider callbacks with their documented retryable response, or durably capture them for later replay; do not acknowledge a dropped event. Choose the mechanism in P0 from actual provider retry contracts. Coordinate external schedulers and prevent two worker generations from running.
4. Capture final complete product/auth exports and manifest after the barrier; do not assume two independent snapshots line up before it. Preserve all current records and final cursor/outbox high-water marks. A separately proven CDC/logical replication procedure can replace this only after equivalent no-loss rehearsal and independent replication of both DBs.
5. Restore and reconcile on the target while writes remain closed. Load unchanged required data-derived keys and refreshed host connection credentials. Verify decrypt/index/session/RLS behavior and current/oldest client contracts with isolated synthetic checks. Record source/target counts/digests and the barrier time.
6. Route stable domains/services to the new host. Fence old application instances at their write credentials/ingress as needed so DNS caches cannot create split writers. Old endpoints may proxy to the sole target or return retryable maintenance; they must not write the frozen source.
7. Make the go/no-go decision **before target writes reopen**. If gates pass, open target writes and resume a single generation of workers gradually. Replay captured callbacks/imports with idempotency checks and monitor sign-in, refresh, sync, balances, queue lag and errors. Keep source read-only, encrypted snapshots and old key material throughout the defined observation/recovery window.
8. Retire the old host only after reconciliation, a new target-produced paired backup is restored successfully elsewhere, offline clients have resumed sync, integration callbacks work and the source retention/recovery window expires. Revoke old host credentials without deleting keys still needed by retained data/backups.

### D. Rollback rules

- **Before target writes:** restore routing to the unchanged source only after proving the target accepted no writes, disabling target writers and retaining the final source barrier state. Keep security containment in place.
- **After any target writes:** switching DNS back to the old snapshot loses accepted changes. Freeze writers, retain/export the target, then use a rehearsed full reverse transfer or lossless change replay to restore both DBs to a compatible source and reconcile before reopening. Reverse transfer includes auth/session/deletion state and every job/idempotency record. If source capabilities/schema cannot accept the new state, use forward repair with writes paused as required; record this before cutover rather than offering a false one-click rollback.
- Never restore an old production dump over new acknowledged data as a routine code rollback. Preserve forward-compatible additive schemas and roll back code only to a release that can read the current encryption/schema and still enforces the security fixes.

## 7. Verification and completion evidence

Luna 6 builds the release evidence matrix; each owning agent supplies meaningful tests for its changes. Existing tests may already cover part of it; revalidate them instead of writing duplicate assertions. The following are requirements for implementation, not tests claimed as run for this document.

| Test group | Required cases and evidence |
|---|---|
| Install/upgrade | Empty product+auth DBs; upgrade deployed baseline including missing hashes and legacy ciphertext/plaintext; actual Compose migration command; interrupted/repeated migration; checksum mismatch; one DB succeeds/other fails; no demo seeds. |
| Cryptography | Correct/missing/wrong keys, tampering, unknown version, randomized nonces, canonicalization variants, full hash verification, duplicate identities, dual-version rotation and retained-backup decryption; no plaintext downgrade or leaked keys. |
| Authentication | Email/phone where enabled, existing/new/legacy accounts, onboarding/link/recovery, wrong-purpose/expired/replayed OTP, exactly-one concurrent success, attempt races, enumeration limits, refresh rotation/retry, device revoke/logout-all, disabled/deleted/guest denial and five-second revocation bound. |
| Authorization/transport | Actual API/auth/worker/migrator/backup roles, cross-user reads and foreign references, protected admin functions, function search paths, ledger write denial, untrusted proxy headers, DB TLS trust/hostname errors and internal-service outage. |
| Supported clients | Current and oldest supported mobile/console against the new server; API/auth deployment order; fresh install, encrypted/plain SQLite upgrades, legacy tokens, offline first screen, guest wallet, pending SMS/edits/tag/review queues, sign-out/account switch/relogin and sync cursor continuity. |
| Device recovery | Migration process death at every boundary, key provisioning failure preserves readable old DB; post-switch wrong/lost key preserves ciphertext without wiping; separately prove recovery-key/export restoration if promised. Also low disk, post-switch new writes, WAL/attachment consistency, receipt add/view/delete, OCR cleanup, gallery preservation, keystore/device restore and unchanged Android backup setting. |
| Integrations | Gmail stays on-device/read-only; IMAP save/test/poll/SSRF/DNS/timeout/role/lock; provider mail failure and retry; callback replay/dedupe; notification delivery/rewards/AI worker restart; console email login, cookies/CSRF/CSP/non-admin denial. |
| Financial/data parity | All-table counts and canonical digests, UUID/reference/sequence preservation, sync/idempotency/tombstones, totals and rewards/caps/benefits/referrals by supported period/currency, full source-to-target-to-recovery-host round trip and oldest offline client resync. |
| Recovery/lifecycle | Both DBs plus external objects, off-host key recovery, incomplete/failed upload, missing archive, decrypted restore, deletion after partial failure, deleted/revoked identity not resurrected, replay retention and independent notifications for stale backups/jobs. |
| Free-host reliability | Measured memory/connection/storage limits, cold start/sleep, DNS/CA change, slow provider, worker backlog, backfill pressure, export/restore exhaustion and API/auth availability while bounded jobs run. No certified capacity from a small local fixture. |
| Deployment/cutover | CI current-session smoke identity, migration/job readiness before traffic, write barrier covers all writers, DNS-cache old writers fenced, source read-only, target write then failback rehearsal, no accepted-write loss and target-origin backup restored independently. |

Implementation commands are discovered from the checked-in toolchain: API `npm test`, auth `npm test`, relevant DB role/invariant tests, `deploy/tests/test_restart_services.py`, Flutter analysis/tests and signed-device checks for changed paths. Run local synthetic checks first, then restricted restore/deployment rehearsals. Never use old passing test totals as a new result. Replace the production smoke test's synthetic signed JWT subject in `.github/workflows/deploy-prod.yml` if it cannot satisfy the now-authoritative session contract; do not weaken production session verification to accommodate a smoke test.

Completion requires the recorded commit, data/migration/key-format versions, all applicable matrix results, source/target reconciliation, restore timing, operator runbook and remaining provider limits. A finding is not closed by editing its description.

## 8. Audit coverage and six Luna implementation packages

| Package | Ownership and required audit coverage | Dependency / write coordination |
|---|---|---|
| Luna 1 — schema, TLS and permissions | P1 runner/baseline/checksums, S10/S17/S18 schema support, A03/A04/A06/A08 bootstrap, role/extension/provider manifest. | Own DB migration filenames and setup roles; review all other packages' SQL. Serialize edits to shared Compose/migration files. |
| Luna 2 — identity and cryptography | P2/P3; S01–S09, S11, S15/S16/S18, C03/C04, M3/M10; session/JWT/refresh/key contracts and normalized contacts. | Requires P1 recovery and runner. Own auth logic; coordinate `api/src/auth.js` and console contract changes with Luna 4/5. |
| Luna 3 — backup, recovery and lifecycle | P1 backups, P4 erasure/schedulers, sections 5–6; A01/A02/A08, B04, M6, SD04. | Own backup/restore/deploy recovery scripts. Shared deployment/role edits land through coordinator; never race Luna 1. |
| Luna 4 — API and integration isolation | P4; S12/S14/S16/S17, B01–B05/B07/B08, SD01–SD03/SD06–SD08, A07 and D01–D05 safety proposals. | Own extracted API integration/worker modules. `api/src/index.js` has one active editor; no concurrent broad refactor. Keep financial cleanup separate from security repair. |
| Luna 5 — mobile and console compatibility | P3 console/P5; S13, B06 revalidation, A09, M1–M10, SD02/SD05 client work; native/device backup/storage/receipt behavior. | Requires stable auth/API contracts. Keep server, console and device storage rollouts independently releasable. |
| Luna 6 — independent verification and release | P6/P7 evidence; N01–N04 fresh dependency advisory review, C01/C02/C05–C07 consumer checks, W01–W07 truthful docs, all acceptance groups and SD04/SD05 contract/CI gates. | Review each completed package independently. May add test/CI changes, but does not merge conflicting implementation edits or declare production fixed from local tests. |

For M1/M2, review actual release secret/dependency inventory across native/Dart/Node; upgrade advisory-affected chains compatibly and preserve lockfiles/release evidence. N01–N04 applicability must be rechecked against current installed versions. For C/D work, an evidence-based decision to defer retirement is acceptable; it is not acceptable to delete preserved customer data or conceal an open security defect.

The six packages are work assignments, not a requirement to run six agents simultaneously. This environment currently permits three workers alongside the coordinator. Run independent tasks in batches, use separate branches/worktrees for implementation if needed, and have one coordinator integrate shared files and migrations. Agents cannot independently deploy, rotate production keys, execute bulk data jobs or change schemas out of order. [Detailed Luna handoff](security-luna-handoff-2026-10-22.md).

## 9. Remaining facts to establish before implementation release

- Actual free providers, deployed PostgreSQL versions/roles/extensions and quotas, disk encryption guarantees, backup destinations and off-host recovery operator.
- Deployed data volumes, existing plaintext/ciphertext/hash coverage, contact conflicts, released client support window, acceptable maintenance interval and measured restore time.
- Source of truth for active/deleted/pending contact reuse, raw import and backup retention, allowed IMAP providers and externally delivered webhook retry contracts.
- The destination PostgreSQL hosting/provider and its verified version, extension, role, TLS and full-data restore compatibility. PostgreSQL itself is confirmed to remain in use.
- Local-only device recovery requirements, especially unsynced data and receipt portability after device/key loss.

These are preflight inputs, not reasons to leave code review or local implementation preparation unfinished. Discover available configuration/capabilities without exposing secrets, and resolve missing deployment-specific decisions before the dependent rollout.

## References checked for this plan

The portability design uses PostgreSQL's documented logical dump/restore and separate-global-object behavior, rather than provider-specific backup APIs. See [backup approaches](https://www.postgresql.org/docs/current/backup.html), [pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html), [pg_dumpall](https://www.postgresql.org/docs/current/app-pg-dumpall.html) and [pg_restore](https://www.postgresql.org/docs/current/app-pgrestore.html). This is a planned application-level consistency and reconciliation procedure, not a claim that two independent dumps create one cross-database transaction.

Connection-string SSL parameters can replace an explicitly supplied SSL object, so the proposed TLS configuration must test the actual parsed configuration. [node-postgres SSL documentation](https://node-postgres.com/features/ssl).

Separate key purposes, recovery copies and rotation procedures follow the lifecycle concerns described in [OWASP key management guidance](https://cheatsheetseries.owasp.org/cheatsheets/Key_Management_Cheat_Sheet.html). The concrete field formats, staged rollout and free-host baseline above are PandaPay design decisions and still require implementation evidence.
