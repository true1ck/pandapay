# Luna handoff: security without data loss

Date: 22 October 2026. Parent plan: [security implementation and database portability](security-implementation-plan-2026-10-22.md).

This handoff prepares six implementation work packages. Creating this document does not implement the changes. Start the implementation when the owner requests it; preserve the parent plan's release gates and current-state corrections.

## Shared instructions for every package

Read the parent plan before editing. The owner currently uses **free application hosting and free PostgreSQL hosting** and will move the complete databases later. **The owner has confirmed PostgreSQL will be retained; only hosting/provider changes.** Implement portable PostgreSQL/security behavior; do not make a paid service a baseline dependency. Preserve all existing data, UUIDs, history, encrypted values, key dependencies, financial results and supported client contracts.

Use the current source rather than treating the 19/20 October audits as current deployed facts. Record a baseline commit and check applicable repository instructions. Do not read secrets into logs, copy `.env` into artifacts, run probes against customer accounts, or export real customer data into CI. Use synthetic data for automated tests and restricted environments for complete backup/restore exercises.

For every task:

1. Explain the current behavior with source evidence and decide whether the finding is open, partial or already fixed in source. An already implemented fix needs verification, not a second competing implementation.
2. Define the supported client/schema/key-format compatibility window and concrete rollback before changing persistence or contracts.
3. Add schema support before dependent readers/writers, using the canonical migration flow. No SQL migration, backfill or key rotation runs independently in production. Never edit an applied migration to make a checksum mismatch disappear.
4. Use bounded retries/batches/checkpoints, lock/time limits and explicit success verification. Do not merge or discard conflicting accounts, reset outboxes, treat decrypt failure as an empty store, or regenerate keys during a host move.
5. Test the changed security property, positive supported behavior, legacy upgrade, interruption/restart and failure handling. A passing old test suite or a green health endpoint alone is insufficient.
6. Return a reviewable diff, exact tests/results, migration/config instructions, runtime resources, rollback/recovery behavior and remaining deployment checks. Do not claim production security from source tests.

Current important corrections:

- `auth/scripts/migrate.js` **does** contain phone-hash backfill. Production Compose runs `db/scripts/migrate.sh`, which applies its SQL without invoking that backfill. Repair the execution path and make the existing algorithm bounded.
- Current auth/session/OTP code contains fixes added since the old audit. Preserve subject-bound signup/contact proof, atomic consume, secure randomness, current-session verification and its unavailable/invalid distinction.
- Current console supports email OTP. Preserve it; the old phone-only finding is historical.
- Existing scheduled and predeploy backups omit auth and save product dumps on the host. A restore rehearsal for both databases is a prerequisite for data transformations.
- Preserve `SMS_LEARNING_HMAC_KEY` where historical sender fingerprints depend on it, alongside encryption, identity, referral and session keys. A disabled worker does not make its historical key disposable.

## Coordination and integration

Use one coordinator and six named packages. With three worker slots, run batches. Independent implementation may use separate branches/worktrees, but every migration and shared-file change is reviewed and integrated in one order.

Shared files include `api/src/index.js`, `api/src/auth.js`, `db/scripts/migrate.sh`, `db/setup_app_role.sql`, all Compose files, deploy scripts and CI workflow configuration. Assign one active editor; other packages submit focused proposed patches or wait for the coordinator's integration. Workers must not overwrite each other's environment/route/grant/migration changes.

Suggested dependency sequence:

| Step | Work |
|---|---|
| Baseline | Coordinator captures P0 actual deployment/contract/key inventory. Luna 6 prepares synthetic baselines; immediate containment fixes can be reviewed separately. |
| Batch A | Luna 1 prepares runner/baseline/TLS/roles; Luna 3 prepares complete encrypted backup/restore; Luna 6 builds recovery/upgrade gates. Integrate shared deployment files sequentially. |
| Recovery gate | Demonstrate both-DB/key restore on another instance and canonical empty/upgrade migration paths before accepting data transformation. |
| Batch B | Luna 2 implements staged identity/encryption; Luna 4 fixes scoped integrations/workers; Luna 5 prepares compatible clients/device encryption prototype. Serialize dependency changes, especially auth contracts/SQL/API entrypoint. |
| Integration | Coordinator stages P2–P5 changes in the parent plan's order. Luna 6 reviews each package and runs current/oldest client and real-role checks. |
| Release rehearsal | Reuse Luna 3 for full dataset/key move and rollback rehearsal, Luna 5 for signed-device upgrades, Luna 6 for independent acceptance evidence. P7 retirement happens only after the observation and recovery windows. |

Do not deploy every package in one large change merely because all branches are ready. Prefer small releases with backups and measured gates. Security containment remains active through rollback.

## Package 1 — Luna: migration runner, verified TLS and permissions

Suggested starting files: `db/scripts/migrate.sh`, `db/migrate/Dockerfile`, `auth/scripts/migrate.js`, `auth/db/pandapay-auth/init.sql`, auth/product migration directories, `db/setup_app_role.sql`, `api/src/db.js`, `auth/src/db.js`, connection config and Compose migration services.

Deliverables:

- One canonical runner covering product/auth baseline, incremental DDL and explicit verified data jobs. Separate privileged auth migration credentials from auth runtime credentials. Route actual Compose/CI/deploy commands through it.
- Checksummed independent ledgers, dedicated-session migration lock, timeouts, partial-step recovery, explicit nontransactional index jobs and no runtime ledger writes. An empty destination and an existing released schema must converge without fabricated ledger entries.
- A role/privilege manifest with narrow API/auth/worker/backup operations, reviewed definer functions, fixed safe search paths and no unnecessary PUBLIC/default grants. Do not break migration order by revoking grants before replacement capabilities exist.
- Verified DB CA/hostname configuration in both initialization paths and every administrative client; handle URL SSL settings without overriding trust. Local non-TLS is explicit.
- Portable extension/collation/provider-capability checks and scheduler inventory.

Gate: actual runner tested from empty/old/partially upgraded DBs; wrong keys fail migration; runtime roles cannot modify ledgers/bypass owners; old and new app release contracts still work. Review all other packages' SQL filenames, lock budgets and grants.

## Package 2 — Luna: auth, encryption, identity and sessions

Suggested starting files: `auth/src/utils/fieldEncryption.js`, `encryptedPhoneSearch.js`, `auth/scripts/migrate.js`, auth route/service/middleware modules, `api/src/auth.js`, `auth/INTERNAL_SESSION_CONTRACT.md` and auth migrations owned jointly with Luna 1.

Deliverables:

- Explicit legacy/new ciphertext formats and key IDs in parallel storage, a secure compatible bridge release and transactional dual writes before switching reads; no rollback to a v1-only writer after activation. Strict production key validation, controlled tamper/wrong-key errors and no plaintext fallback. Apply the same transition to IMAP credentials; preserve current formats during a pure host move.
- Unified phone/email normalization policy; bounded/checkpointed phone backfill; transactional ciphertext/index updates; full verification; duplicate identity reconciliation without account merging; lifecycle-aware unique indexes and normal conflict responses.
- Durable purpose/challenge/contact/subject binding, atomic single-use/attempt behavior, supported login/link/recovery flows and a compatible OTP-length transition if selected.
- Auth/API/refresh/device lifecycle agreement and the declared cache revocation bound; secure outage behavior, legacy-surface retirement after consumer checks, redacted logging, correct proxy trust and durable free-host abuse budgets.
- Key inventory and separate encryption/HMAC/JWT/refresh rotation procedures; no key changes bundled into host cutover.

Gate: full legacy data/index/decryption verification, concurrent identity/OTP tests, wrong-purpose/replay/cross-account rejection, current/oldest client login/refresh/recovery, correct 503/401 behavior and key-preserving restore.

## Package 3 — Luna: complete backups, restore, lifecycle and host move

Suggested starting files: `db/scripts/backup.sh`, `restore_drill.sh`, `db/backup/`, `deploy/deploy.sh`, backup Compose services, lifecycle SQL/worker modules and deployment runbooks.

Deliverables:

- Complete paired product/auth backup sets, encrypted before transport, with detailed encrypted manifest, verified off-host copies, independent recovery-key custody, separate upload/restore status, quota-aware retention and tested alerts.
- Actual isolated restore of schema/data/roles/ACLs/extensions/sequences/jobs and required keys, with all-table/financial/identity reconciliation. Recreate only reviewed application roles; do not blindly import provider globals.
- Durable cross-database deletion and restore-time deletion/revocation replay; scheduled jobs with leases/idempotency/heartbeats that account for free-host suspension.
- Measured PostgreSQL provider-to-provider cutover runbook: all-writer barrier, pending callback handling, full data/config/key export, stable endpoints, old-host fencing, single worker generation and verified target backup.
- Distinct rollback before/after accepted target writes. After target writes, require full reverse transfer or tested lossless replay; never suggest DNS-only failback to a stale DB.

Gate: destroy/recreate the isolated target, recover keys and both databases from off-host copies, reconcile every preserved category and demonstrate failed upload/partial deletion/target-write rollback behavior. Record measured RPO/RTO and actual free resource limits.

## Package 4 — Luna: API authorization, ingestion and workers

Suggested starting files: focused API integration modules, `api/src/index.js` under an exclusive edit assignment, `imap_poller.js`, `imap_test.js`, `imap_client.js`, notification/provider services, rewards/AI workers and associated SQL operations.

Deliverables:

- Scoped worker enumeration under owner RLS, correct advisory-lock/lease lifecycle, bounded processing and conservative retries. No superuser API workaround.
- IMAP provider/destination validation at save/test/poll, DNS/IPv4/IPv6/port restrictions, timeouts and no raw secret logs; staged legacy-pgcrypto/new-envelope credential handling coordinated with Luna 2.
- Atomic lounge foreign-ownership checks, permission-correct/idempotent partner callbacks and sanitized backup health.
- Explicit Google-login versus on-device Gmail contracts; protected/retired debug/dashboard paths, preserving current console operator flows.
- Durable important-event delivery using existing outboxes where appropriate, duplicate/restart recovery, provider isolation/backpressure and financial fixture parity.
- Separate reviewed proposals for dedupe/index cleanup and clock-safe sync transitions; keep source records/mappings and supported old-client conflict behavior.

Gate: actual non-bypass role checks, cross-user denial, DNS-rebinding tests, restart/session-lock behavior, callback retries, provider outage, queue recovery and unchanged financial results. Broad API extraction is a later independent change.

## Package 5 — Luna: mobile, console and local data preservation

Suggested starting files: app token/environment/auth providers, `app/lib/data/local/`, sync/import/attachment/OCR components, Android/iOS security configuration, console auth/token/client/config modules.

Deliverables:

- Preserve stable auth/API contracts, offline snapshots, per-account pending work, local guest data, sign-out/account-switch semantics, refresh retry and on-device Gmail consent.
- Same-origin console HttpOnly session/BFF transition with CSRF/Origin/CSP checks and working email operator sign-in. Define old cached-bundle Bearer overlap, minimum console version, reload/re-authentication and retirement conditions; mobile Bearer remains supported.
- A verified encrypted SQLite migration prototype before selecting a library; whole-database/queue/cursor/WAL copy, disk-space preflight, crash-safe atomic switch and explicit post-switch rollback/data recovery. No automatic wipe on key failure.
- Verified local receipt encryption and temp cleanup without cloud upload or deletion of gallery originals; unchanged backup restrictions and explicit key-loss policy. Before activation a key provisioning failure preserves the readable old DB; after activation permanent nonexportable-key loss preserves ciphertext but cannot promise decryption without a tested recovery mechanism. Resolve recovery requirements before encrypting irreplaceable local-only data.
- Current/oldest supported client checks, native release builds, signed-device upgrade checks, key-store failures and package/advisory evidence for changed dependencies.

Gate: process death/low disk/offline/key-unavailable cases preserve pending data; old supported users can log in and sync after server migration; local-only data is honestly distinguished from server-recoverable data. Do not advertise cross-device receipt/unsynced-data recovery without a separate encrypted export/recovery feature.

## Package 6 — Luna: independent security verification, CI and release evidence

Suggested starting files: existing API/auth/DB/mobile tests, `scripts/smoke_test.py`, deployment tests, CI workflows, dependency lockfiles and dated audit/architecture/privacy/deploy documentation.

Deliverables:

- Map every audit ID to current status, owning package, implementation commit, test and target-environment evidence. Recheck current dependency advisories; never cite the old counts as current.
- Meaningful synthetic current/oldest-client contract fixtures and real-role auth/DB tests; migration-from-empty/deployed-upgrade/failure/restart gates, cryptographic negative tests and all-table round-trip checks.
- Updated production smoke identity that satisfies authoritative current-session verification. Never relax production auth for a synthetic smoke subject.
- Full parent-plan section 7 matrix, signed-device upgrade evidence, cold-start/quota/backlog exercises and independent full-data restore/cutover review.
- Docs/security/privacy claims matched to evidence, secrets absent from artifacts, no drop/dedupe justified solely by empty local tables, and measured recovery/resource constraints published to the operator.

Gate: provide pass/fail evidence per release requirement and identify remaining production inputs. The coordinator resolves blockers before deployment; a plan, a source fix or a passing old suite is not production certification.

## Required completion report

Each agent reports changed files, resulting supported behavior, migration/config prerequisites, exact checks/results, data/key preservation evidence, rollout/rollback procedure, unresolved provider facts and the next dependency. The coordinator integrates these into one release record linked to the parent plan. Implementation is complete only after the full release matrix and recovery rehearsal pass, followed by separately verified deployment.
