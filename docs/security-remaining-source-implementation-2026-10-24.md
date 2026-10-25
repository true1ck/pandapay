# Remaining security implementation — 24 October 2026

This records the source delivered after the R4/R5 capability batch. Parent: [R1–R10 plan](security-remaining-implementation-plan-2026-10-23.md). Evidence: [remaining-batch verification](../artifacts/security-implementation-2026-10-24-remaining/batch-verification.json). Changes are local on `dev`; deployment acceptance remains separate. The newer [OTP/journal/OCR follow-up](security-followup-implementation-2026-10-24.md) supersedes the affected source/configuration details below and has separate exact-candidate evidence.

## What is implemented

| Batch | Delivered source | Remaining acceptance |
| --- | --- | --- |
| R3 | All auth logging schema changes are migration-owned. Explicit bounded retention CLI for optional access diagnostics and expired abuse buckets. | Actual policy/access review, maintenance login, installation, load and alert delivery. |
| R4 | Catalog-only privilege audit with explicit product/auth policies, inherited/PUBLIC/default/column/owner/definer checks and strict failure exit. | Review and repair broader legacy grants on a current restored copy; no blanket revocation was applied. |
| R6 | Same-origin console cookie gateway, encrypted server sessions, CSRF/origin checks, browser storage removal, CSP deployment template; proof-only account-status endpoint. | Real browser/CSP/proxy/operator acceptance, supported old clients; legacy anonymous lookup and four-digit OTP transition remain. |
| R7 | Durable two-database soft deletion, 30-day grace, cancellation, retries, session revocation, immutable UUID tombstones and explicit post-restore reconciliation. | Independently retained deletion journal, retention/erase policy, operational monitoring and remaining scheduled jobs/outboxes. |
| R8 | Password-free account-bound encrypted recovery API, quota-controlled escrow and Flutter capture/restore/crypto/private-temp modules. | Active recovery UI, app operation barrier, exhaustive schema coverage and signed-device acceptance. Live SQLite/receipt encryption stays disabled. |
| R9 | Restored-copy read-only duplicate/reference/index/financial report. | Review actual candidates and plans, approve survivor/ID mappings, then separately implement any justified reconciliation. |
| R10 | Exact-source release checker with hashes, evidence freshness, quotas, retained-key presence, feature and provider/device/custody gates. | Actual-data current-candidate recovery, intended provider cutover/failback, independent custody and signed clients. |

No new end-user password is introduced. Existing phone/email OTP and masked-email recovery stay available. No live database, retained encryption key, contact owner, provider account or notification work was changed by this batch.

## Migration and configuration order

Use the existing fenced deployment procedure. Rehearse the **complete paired database export and upgrade on an isolated restored copy** first. Never edit an applied migration, bypass an unresolved checksum, run legacy hard deletion or restore global privileges into a shared cluster.

New auth migrations:

1. `0008_auth_audit_risk_level.sql` preserves existing audit records and supplies the schema required by DML-only audit logging.
2. `0009_console_browser_sessions.sql` creates the private encrypted-session store and restricted capability.
3. `0010_durable_account_lifecycle.sql` creates auth tombstones and fixed deletion functions.

New product migrations, in order:

1. `20261023191847_durable_account_lifecycle.sql` creates private request/tombstone state and disables the old physical-delete function. Existing legacy request/cancel updates mirror into the ledger, including when new API activation is off.
2. `20261023192644_account_recovery_escrow.sql` adds the private bounded encrypted snapshot store, using the lifecycle UUID fence.

Original financial/profile/contact rows and UUIDs are retained. Whole PostgreSQL backups include the new private schemas. Portable account export classifies operational tables separately; it never exports another account's recovery key.

## Console web sessions

The **new web console and its gateway must be promoted together**. Web now uses relative `/browser` URLs. Deploying only the new static bundle against an old auth server would prevent console login. Native console bearer behavior remains supported.

- Serve the console bundle and `/browser/` under one HTTPS origin, using `deploy/nginx/console.conf.example`. Configure exact `CONSOLE_BROWSER_ORIGIN` and the approved browser-origin allowlist. Keep the existing trusted-proxy topology and overwrite incoming forwarding headers.
- Build with `flutter build web --release --csp --no-web-resources-cdn`; serve the bundled assets from that origin. Runtime CSP/browser interaction is still a release check.
- Enable `CONSOLE_BROWSER_ENABLED=true` only after gateway/database readiness. Supply a **separate retained** 32-byte canonical base64 `CONSOLE_SESSION_ENCRYPTION_KEY`, dedicated `CONSOLE_SESSION_DATABASE_URL`, and fixed `CONSOLE_AUTH_UPSTREAM`/`CONSOLE_API_UPSTREAM`. No replacement key is generated by startup.
- The migration job can provision `console_session_runtime` using optional `CONSOLE_SESSION_DB_PASSWORD` (at least 32 bytes). Re-running does not rotate an existing login password. It inherits only `pandapay_console_session`; no raw identity/refresh table privileges are granted.
- Gateway stores only a hash of the random opaque cookie ID plus AES-GCM encrypted credentials. Cookie is host-only Secure/HttpOnly/SameSite=Strict; absolute lifetime 12 hours, idle limit 30 minutes. Browser JSON contains no bearer/refresh token. Old preference tokens are cleared; an existing browser user may need to sign in once with existing OTP.
- Every gateway request requires the custom browser header. Mutations require exact Origin; session proxy/logout require per-session CSRF. Only fixed admin routes and categories GET can be relayed. Upstream redirects and arbitrary hosts are refused.
- A per-session database lock serializes refresh. Stable refresh request IDs and commit-before-rethrow preserve confirmed rotations across retries. Logout removes server state. Access-token revocation still obeys the existing bounded session cache; cookies do not make XSS harmless.

A dedicated pool caps at three connections; at most two upstream session operations hold connections. Readiness has a reserved slot and rejects broad identities, owner/nested-role access or missing table permissions.

## Proof-only account status

`POST /auth/v2/account-status` accepts an empty body/query and the current account's bearer session, requiring recent verified phone/email proof or a linked verified Google factor (five minutes), current device and active non-guest identity. It returns only that verified account's masked contact hints. It cannot look up an arbitrary submitted email/phone.

The old anonymous `check-user` response is retained for supported clients, behind the shared abuse budget. S15 remains partial until a versioned client transition removes enumeration. Legacy OTPs remain four digits. The follow-up adds isolated six-digit v2 challenges; client activation/legacy retirement remains pending.

## Bounded auth retention

The CLI never loads `.env`, starts a scheduler or changes grants. Default invocation is a dry run; with no explicit policy it preserves every row.

```sh
node auth/scripts/retention.js --help
node auth/scripts/retention.js
# Only after reviewing the count-only report and explicit policy:
node auth/scripts/retention.js --apply
```

Provide `AUTH_RETENTION_DATABASE_URL` through protected operator configuration, with verified `DB_SSL`/CA settings. A separate maintenance identity needs only the reviewed scopes and row-lock permissions; the normal auth login remains INSERT-only for access diagnostics.

| Setting | Bound |
| --- | --- |
| `AUTH_DB_ACCESS_LOG_RETENTION_DAYS` | Explicit 30–3650 days; unset preserves diagnostic rows. |
| `AUTH_ABUSE_STATE_RETENTION_DAYS` | Explicit 1–365 days after expiry; active/unexpired budgets remain. |
| `AUTH_RETENTION_BATCH_SIZE` | 1–1000; default 100. |
| `AUTH_RETENTION_MAX_BATCHES` | 1–100; default 10. |
| `AUTH_RETENTION_MAX_DURATION_MS` | 100–60000; default 10000. |

Advisory job locking, `SKIP LOCKED` batches and deadlines bound concurrent work. `auth_audit`, OTPs, accounts, contacts and financial history are never purged by this tool. No actual schedule or policy was installed.

## Durable account lifecycle and restore

Defaults: `ACCOUNT_LIFECYCLE_ENABLED=false`, `ACCOUNT_LIFECYCLE_POLL_INTERVAL_MS=0`; the product database's `account_lifecycle.control.worker_enabled` is also false. Legacy request/cancel success shapes remain when disabled. The migration prevents old cron physical deletion even before worker activation.

Activation requires both services, all user/sync transaction fences, dedicated `ACCOUNT_LIFECYCLE_DATABASE_URL` and `AUTH_LIFECYCLE_DATABASE_URL`, the existing internal-service secret and verified TLS. Optional migration-only bootstrap variables are `ACCOUNT_LIFECYCLE_DB_PASSWORD` and `AUTH_LIFECYCLE_DB_PASSWORD`. The logins inherit only their named lifecycle capability. Product pool max one; auth max two. Readiness rejects unsafe grants and role drift.

- Request/cancel retains the 30-day grace. After a due claim, cancellation is refused and user transactions are fenced by the UUID tombstone.
- Worker takes one job immediately before remote work; at most 25 per cycle, five-minute cycle budget, 60-second lease, ten attempts before blocked operator state. Poll interval, if enabled, is 60 seconds to one hour. Overlap is refused.
- Auth atomically marks the original UUID deleted/inactive, bumps token version once, disables devices and revokes refresh. Product history remains. Replays cannot reactivate that UUID or attach its history to a new UUID. Deleted contacts remain reusable under the prior active-contact policy.
- `api/src/account_lifecycle_recovery.js` reconciles both tombstone stores only when the operator explicitly declares services quiesced. If both backups predate deletion, supply a verified independently retained latest deletion journal. Old backups cannot infer missing future deletion events.

**The follow-up implements an external encrypted tombstone journal, separate latest checkpoint and quiesced reconciliation; keep lifecycle activation off until their actual independent storage, recovery and monitoring are installed and rehearsed.** No physical erasure/financial-retention policy is assumed. Unfinished inbound-mail retention, merchant/divergence jobs, heartbeat alerts and notification outboxes remain tracked as A08/R7.

## Password-free account recovery source

Defaults: `ACCOUNT_RECOVERY_ENABLED=false` and `account_recovery.control.enabled=false`. No existing app flow uploads phone-only data or encrypts its live database.

The new modules support an explicit, account-bound recovery snapshot using the user's existing recent phone/email OTP. A random per-snapshot archive key encrypts the local archive with XChaCha20-Poly1305; the server wraps that key with AES-GCM under a separate retained `ACCOUNT_RECOVERY_WRAPPING_KEY` and stable `ACCOUNT_RECOVERY_WRAPPING_KEY_ID`. Both layers bind the original account and snapshot UUID. A new phone can retrieve its key/ciphertext after existing sign-in. There is no extra password or user-managed key-file prompt.

- Routes: POST/GET/DELETE `/account/recovery/snapshots`, GET `/:snapshotId`. Recent proof is required for all. Upload uses a separately bounded binary media type, not an increased global JSON limit. Exact nginx upload path permits 6 MiB; API ciphertext cap is 5 MiB plus bounded metadata.
- Explicit per-operation consent controls receipts and unsynced queues. Client validates namespace/scope, self-decrypts, uploads and downloads/decrypts for digest verification. Lost acknowledgement retries accept only identical original snapshot data/key, preserving mutation IDs.
- Limits: 5 MiB per archive, two copies per account, 50 MiB global logical storage, conservative 350 MiB physical product-database guard and 15-minute new-snapshot cooldown. Serialized quotas never evict another user's backup. A refused upload preserves existing copies. These are conservative source defaults, **not a measured current provider quota**; compression/storage overhead and sustained DB growth still need measurement.
- Local restore requires a fresh matching namespace, stages private receipt copies and rechecks inside a synchronous SQLite transaction. It preserves IDs/history and resets in-flight markers for retry. Unknown nonempty unscoped tables and ambiguous receipt ownership fail closed.
- New private workspace helper removes only marked app-owned copies, with a maximum 50 stale workspaces and minimum one-hour age. It preserves gallery originals and symlink targets. The follow-up integrates OCR preparation/startup cleanup. Export/share-file lifetime and signed-device acceptance remain separate.

**Not yet delivered as an enabled product:** recovery UI/provider wiring, a real app-wide operation barrier, exhaustive lazy-table coverage, native key custody and resumable live SQLite/receipt conversion. The snapshot module's explicit `quiesced` precondition alone cannot stop active application work. Signed-device crash/low-disk/offline/account-switch/key-loss tests must pass before storage encryption activation. Account compromise also grants access to escrowed recovery data; treat its recent-proof endpoint and wrapping key as sensitive.

## Read-only privilege and data review

These tools never read a default `.env` or use an ambient `DATABASE_URL`. Supply URLs through protected process configuration; never copy values into commands, reports or Git.

```sh
node db/scripts/audit_runtime_privileges.js --scope product --strict
node db/scripts/audit_runtime_privileges.js --scope auth --runtime-role ACTUAL_AUTH_LOGIN --strict
node db/scripts/review_data_cleanup.js --restored-copy --scope product --require-complete
node db/scripts/review_data_cleanup.js --restored-copy --scope auth --require-complete
```

Privilege audit uses `PRIVILEGE_AUDIT_DATABASE_URL` and its `PRIVILEGE_AUDIT_DB_SSL[_CA|_CA_FILE]` settings. Data review uses a **fresh restored copy** via `DATA_REVIEW_DATABASE_URL` and `DATA_REVIEW_DB_SSL[_CA|_CA_FILE]`. Run separately against the corresponding product/auth database. Auth role names must match the actual deployment. Audit reports include catalog names/hashes, not secret values or user rows. Data reports contain bounded aggregate counts/digests; full visibility and completeness are required.

Strict audit exits 2 on findings; incomplete data review exits 2 with `--require-complete`. Existing broad grants are reported without revocation. Duplicate candidates preserve business discriminators; no survivor, UUID merge, history deletion or index drop is automated. Review actual financial/reference invariants and query plans before proposing mutations.

## Release gate and migration portability

```sh
node db/scripts/release_security_check.js --template
node db/scripts/release_security_check.js --inputs /protected/release-inputs.json --strict
```

The input template contains names/limits only. The checker hashes tracked, dirty, deleted and untracked release source twice, includes dependency locks, validates report/proof hashes and freshness, binds accepted evidence to exact source/configuration and checks enabled-feature proofs. It only reports key names/presence, never values. It does not create credentials or deploy. A strict run with current unknown provider/device/custody inputs correctly exits 2; no release approval is produced.

Repeat full paired backup/restore with original keys and all private schemas, current migrations and target roles on the intended PostgreSQL provider. Record actual source/target/dump-client versions, extension/ACL mappings, connection/disk/provider quotas, downtime, writer fencing and post-write failback. Earlier actual-data recovery and current synthetic proofs have different scopes.

The local Mac recovery job remains daily at 07:45 local time, seven days/seven sets, 1 GiB ciphertext, 5 GiB free floor, 95% disk ceiling and 30-minute runtime bound. One Mac remains one recovery location. Two independent off-host ciphertext copies and separate private recovery-key custody are still required.

## Verification and limits

Earlier remaining-batch synthetic checks passed: 940 API cases (two skipped), 288 auth cases, 100 database/tool cases, 45 backup/setup cases, 21 deployment cases, 1,561 Flutter app cases, 29 console cases and 227 domain-package cases. App analysis has zero errors/warnings and 74 informational notices from existing code; console analysis is clean. The CSP console JavaScript release bundle builds; experimental Wasm compatibility is not certified. All twelve PostgreSQL fixture scripts and paired encrypted recovery pass on native PostgreSQL 18; browser/retention/lifecycle/audit/data-review paths additionally have managed-role PostgreSQL 17 fixture evidence. Exact scope and hashes are in the verification artifact.

An initial container-only database/tool run lacked Git, which its source-inventory regression requires; the unchanged complete tool suite passed with native Node 24/Git. API/auth suites use cached Node 22 images and isolated synthetic providers. OTP templates now use PandaPay branding while preserving the configured sender; actual sender/domain delivery remains a provider check. No actual browser interaction, signed Android/iOS upgrade, provider send, current actual-data restore or live deployment is claimed. Production release readiness remains false when those inputs are absent.
