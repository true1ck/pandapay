# Security follow-up — 24 October 2026

Parent: [remaining source runbook](security-remaining-source-implementation-2026-10-24.md). This batch continues the existing dirty `dev` branch and preserves prior security and notification work. [Verification](../artifacts/security-implementation-2026-10-24-followup/batch-verification.json) records the exact candidate and scope. The full plan and production rollout remain incomplete.

## Versioned six-digit OTP

Auth migration `0011_versioned_otp_challenges.sql` preserves every existing row as protocol 1 and adds explicit protocol/device binding for version 2. Migrate first through the fenced deployment procedure; do not run the new service against an unmigrated database.

New additive routes:

| Request | Required fields | Response |
| --- | --- | --- |
| `POST /auth/v2/request-otp` | `phone_number`, stable `device_id`; optional boolean `recovery_only` | `ok`, `version:2`, random `challenge_id`, `code_length:6`, `expires_in:120` |
| `POST /auth/v2/request-email-otp` | `email`, stable `device_id`; optional boolean `recovery_only` | Same shape, without account-existence fields. |
| `POST /auth/v2/verify-otp` | Original phone/device/challenge, exact six-digit string; optional `device_info`, `recovery_only` | Existing verified identity/token continuation. |
| `POST /auth/v2/verify-email-otp` | Original email/device/challenge, exact six-digit string; optional `device_info`, `recovery_only` | Existing verified identity/token continuation. |

Device IDs use 4–128 letters/digits/colon/underscore/hyphen. Request bodies/queries cannot select protocol version. Version selection comes only from server routing. Email v2 refuses phone/sign-up selectors; it makes no pre-proof identity lookup. Codes are cryptographically random, expire after 120 seconds, have five attempts, and are atomically consumed once. Protocol, challenge UUID, purpose, contact channel/identifier and device hash must agree. Delivery failure discards only its challenge. V2 never uses the development test-code/provider bypass.

Both versions share the existing active-challenge, identifier/purpose/IP and failed-verification abuse budgets. Changing URL/device cannot open a separate unlimited budget. The old four-digit routes and success bodies remain available. No new password is introduced. **Client activation and retirement of anonymous `check-user`/old OTP remain open**; S09/S15 are partial until supported-client/provider acceptance and monitored retirement. Do not infer a full enumeration fix from rate limiting or a new endpoint.

## Durable external denial journal

Product migration `20261024072435_lifecycle_journal_checkpoint.sql` adds an operator-initialized private journal checkpoint and narrow capability functions. It preserves data/UUIDs, fixes the definer search path and restores temporary migration-owner grants. Ordinary app users cannot read/advance checkpoints. With worker activation on, legacy profile updates cannot cancel/reschedule a request after its grace expires. Defaults remain off.

The worker now:

1. Locks the private checkpoint row inside its claim transaction and checks both encrypted journal copies plus the separate latest checkpoint.
2. Claims one due job, retaining the account transaction fence.
3. Encrypts the irreversible UUID/request/generation intent with age, authenticates its hash chain with a **separate retained key**, writes and fsyncs both ciphertext copies and the latest checkpoint at its separate root.
4. Advances the DB checkpoint and commits only after all durable acknowledgements. It then applies the existing idempotent auth soft deletion and acknowledges product progress.

Failure rolls the claim back and never calls auth. A crash after external persistence but before DB commit intentionally leaves an irreversible journal intent and a checkpoint mismatch. API admission/readiness and subsequent user transactions refuse until quiesced reconciliation. Do not remove the journal entry to make readiness green. A lost/uncertain transaction rollback or export unlock destroys the pooled connection.

### Storage and custody

Configure **three distinct, non-overlapping, owner-only roots**: ciphertext A and B, and a separately retained latest-checkpoint root. Local directory distinctions do not prove independent failure domains. Actual mounts, permissions for the container UID, independent custody, capacity and recovery tests are release requirements.

| Variable | Meaning |
| --- | --- |
| `ACCOUNT_LIFECYCLE_JOURNAL_A`, `ACCOUNT_LIFECYCLE_JOURNAL_B` | Two private ciphertext journal roots. |
| `ACCOUNT_LIFECYCLE_CHECKPOINT_ROOT` | Separate private root for authenticated `latest-checkpoint.json`. It is required before a denial can commit. |
| `ACCOUNT_LIFECYCLE_JOURNAL_ID` | Stable 64-lowercase-hex journal identity, preserved across rehosting. |
| `ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY` | Separate canonical base64 32-byte authentication key, retained/escrowed separately from ciphertext. Never reuse the phone/lookup/wrapping keys. |
| `ACCOUNT_LIFECYCLE_JOURNAL_RECIPIENTS_FILE` | age public recipients file. The worker needs public recipients, not a private decryption identity. |
| `ACCOUNT_LIFECYCLE_JOURNAL_AGE_BINARY` | `age` or an explicit absolute binary path. API Dockerfile includes age. |

Per ciphertext root: at most 4,096 records and 64 MiB, 64 KiB per frame. Latest checkpoint storage is bounded to one small file. A minimum 512 MiB free reserve and 5% free filesystem space are required before appending. No automatic journal pruning/key generation occurs. Capacity exhaustion or copy/checkpoint disagreement refuses further denial processing and requires operator attention. Append directory locks are not automatically removed after a crash; verify all processes stopped before an operator repairs a stale lock. Recovery validates the entire bounded authenticated chain before exposing any replay records.

### Operator setup/recovery

These commands read explicit protected process configuration, never a default `.env` or ambient `DATABASE_URL`. Keep workers/services/external writers fenced. Supply actual paths/keys through protected operator configuration, not command-line values or this document.

```sh
# Initial setup only: parents must exist; the three new roots must not exist.
# Capture metadata privately (umask 077), then retain it separately.
node db/scripts/lifecycle_journal.js --initialize

# Operator only: requires the trusted latest checkpoint and private age identity.
node db/scripts/lifecycle_journal.js --verify
node db/scripts/lifecycle_journal.js --reconcile --quiesced
```

Recovery-only variables: `LIFECYCLE_JOURNAL_EXPECTED_CHECKPOINT_FILE`, `LIFECYCLE_JOURNAL_RECOVERY_IDENTITY_FILE`, `LIFECYCLE_REPLAY_PRODUCT_DATABASE_URL`, `LIFECYCLE_REPLAY_AUTH_DATABASE_URL`, `LIFECYCLE_REPLAY_CONTROL_DATABASE_URL`. Product/auth replay URLs use the dedicated narrow function logins; the separate control URL uses the fenced migration/operator identity with control-table access. Runtime function executors are never given direct control-table privileges. Verified TLS uses the existing operator `DB_SSL`/CA policy. The private identity stays on the recovery operator's machine. The expected checkpoint can be the authenticated separately retained latest-checkpoint file or its protected metadata copy; it must be the latest accepted point, not an older backup's checkpoint.

Reconciliation requires the database worker gate off. It refuses a journal that cannot account for the checkpoint already retained by the restored DB. It reviews both DB tombstone lists and external history for conflicting UUID/request/generation ownership before replay. Existing DB-only tombstones are encrypted into the external journal before their checkpoint is installed, including initial setup. Complete capacity is checked first. Product denial is replayed before auth revocation; original financial/profile/contact history remains. A partial failure leaves services fenced. The tool never starts services or enables the worker.

One-copy loss or a crash during an append can leave the roots ahead/disagreeing; use protected source copies, trusted latest checkpoint and the quiesced recovery procedure. No automatic truncation/merge is attempted. Acceptance must rehearse this repair on the actual independent storage. Unknown events missing from every database, journal and trusted checkpoint cannot be reconstructed.

### Export and transaction fence

The ordinary user-transaction helper checks journal admission after acquiring its account fence. Portable restore transactions also acquire that fence. A repeatable-read export now acquires a session-level account lock **before** starting its snapshot, preventing a stale snapshot across concurrent deletion. It releases the exact lock after rollback and discards an uncertain connection. The enabled API blocks admission when the external and DB checkpoints disagree. These controls supplement the existing current account/device/session checks.

## OCR private temporary files

Receipt, spending-screenshot, scanned-PDF and card-variant OCR now write generated images into marked random app-owned workspaces. Preparation is inside the cleanup lifecycle, including card-image variants that fail midway. PDF workspace cleanup runs even when document close fails. Source gallery/picker files are not recursive-cleanup targets.

Startup and OCR invocation reap stale marked workspaces only: default age 24 hours, minimum one hour; at most 200 directory entries inspected and 50 removed per invocation. Fresh/active/unmarked directories and symlink targets remain. Historical unmarked files are deliberately left for a separately reviewed policy. Plugin/device behavior, genuine process-death and low-disk acceptance remain signed-device gates. This does not encrypt the live SQLite database or receipts, enable account recovery uploads, or establish a global app-wide write barrier.

The existing Flutter static-analysis and unit-test workflows were used. App analysis retains the prior informational notices with no new errors/warnings. No dependency versions were changed for Flutter. Both service Dockerfiles now copy source/package/dependencies with explicit node ownership, preserving non-root execution even when a source file has owner-only filesystem permissions.

## Dependency security update

API `body-parser` is locked at 2.4.0, with its required `content-type` update. This addresses the compressed-body trailing-bytes crash described in the [maintainer advisory](https://github.com/expressjs/body-parser/security/advisories/GHSA-27r3-jxmh-p828). The application manifest and compression/body-size contracts remain. A separate-process regression verifies the parser survives that malformed compressed input and still serves health. Current API/auth production dependency audits report zero known advisories; this is not a claim of absence of all vulnerabilities.

## Still required

Broader privilege repair against actual current data, reviewed data/index reconciliation, remaining schedules/retention/heartbeats/notification outboxes, real browser/operator/provider acceptance, recovery consent UI and an enforced app-wide operation barrier, native storage-key custody/resumable conversion, actual-data target-provider upgrade/cutover/failback, signed/oldest-supported clients and independent backup/journal/key custody remain open. All feature activations requiring these gates stay disabled. New keys, mounts, live DDL, provider sends, contact changes, deployment/restarts and Git publication were not performed.
