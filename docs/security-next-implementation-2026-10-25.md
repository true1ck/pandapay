# Security follow-up — 25 October 2026

This batch continues the remaining plan with three bounded code changes. It preserves existing PostgreSQL data, original keys, account UUIDs and the twelve unrelated notification edits. Defaults remain compatible and disabled where previously disabled. Nothing was deployed, no live data/schema/key/contact was changed and no provider message was sent.

[Verification](../artifacts/security-followup-2026-10-25/batch-verification.json) records this batch separately from the [preceding local run](security-local-docker-verification-2026-10-24.md). Local tests do not complete the whole release plan.

## Remaining-work count — 25 October 2026

The [numbered remaining-work register](security-remaining-work-2026-10-25.md) groups the full backlog into **14 implementation packages and 6 validation/rollout gates**. Across 76 tracked findings, 25 are implemented in source, 41 are partial and 10 are open. These counts describe different units and must not be added together. Source implementation is not production closure.


## Implemented in this batch

### Six-digit verified contact replacement

The opt-in mobile flow now uses `/users/me/recovery-contact/v2/request` and `/v2/verify`. Existing four-digit `/request` and `/verify` methods remain compatible by default. The current `PANDAPAY_OTP_V2_ENABLED` build flag selects v2 for login, recovery and replacement together.

A recent existing recovery OTP proof authorizes replacement of the other contact. The body device must match the signed, active device claim checked by auth middleware. A short-lived opaque signed challenge binds account, device digest, replacement channel/value, previous contact fingerprint, exact OTP request UUID, protocol and purpose. V2 has its own JWT audience and six-digit OTP service path, with atomic consume, 120-second maximum TTL and five attempts. Legacy and v2 share the stable account replacement budget. Failed or thrown delivery discards only its matching v2 challenge. The old contact stays until successful verification and a conditional active-account update. Existing active-only contact uniqueness still applies.

The client holds challenge metadata in memory, validates device/contact/protocol/expiry and six digits, and never falls back to four-digit endpoints after an error or malformed response. The linked-contact recognition check remains four characters/digits. No new password, key file or silent upload is introduced. Explicit `AUTH_RETIRE_LEGACY_OTP=true` now also refuses legacy contact replacement with a uniform update-required response; this flag remains false until supported-client/provider acceptance and the monitored compatibility window pass.

### Bounded receipt reconciliation after interrupted restore

Newly restored receipt copies use the dedicated private `account_recovery_receipts/receipt-<32 hex>.bin` directory. A bounded intent journal is flushed and atomically renamed before writing each new file. On the next account-recovery operation, existing-factor/account verification precedes the process operation gate and native SQLite writer lease. Account state is rechecked inside the lease and during reconciliation.

Cleanup considers only valid journal-listed generated names in that reserved directory. All candidate path/schema/reference checks finish before deletion. Every table/column across namespaces is scanned for the generated basename, including pending JSON/text records. Any opaque binary cell conservatively retains all candidates. Missing schema, malformed/oversized journal, unsafe paths/symlinks, query failures or row/byte/schema/time budget exhaustion refuse cleanup and preserve files. Bounds are 256 intent names, 32 KiB journal, 128 tables/2048 columns, 500,000 scanned cells, 64 MiB conservative logical bytes and four seconds of scan admission. Large text cells are size-checked before fetching their contents.

Referenced receipts remain. Gallery originals, ordinary attachments, unjournaled files and older root-level recovery files are never sweep targets. A failed cleanup blocks that recovery operation rather than guessing that files are unused. The journal remains bounded even if that means refusing new receipts until reviewed reconciliation succeeds.

This is a conservative local crash-repair slice, not universal native process-death proof. The journal is not cryptographically authenticated; Dart path validation/deletion has a filesystem race against a hostile local process. Directory fsync/power-loss behavior and complete native/file-writer coverage require signed-device acceptance. Missing/corrupt intent metadata preserves bytes for later operator repair. Live SQLite and receipt encryption remain off.

### Optional operational alert delivery

The [alert adapter](maintenance-alert-delivery-source-2026-10-25.md) reads only bounded private maintenance notices through a separately checked reader identity. Default CLI use is a configuration diagnostic with no database/network connection. Sending needs an explicit command, strict true flag, verified PostgreSQL TLS, approved HTTPS destination, stable source identity and preflighted private state path.

Only fixed job/code/generation/occurrence metadata is sent. DNS answers must be public and are pinned; redirects are refused, response bodies are closed and wall-clock request limits apply. Delivery state is bounded to twelve source-bound job/code identities and uses private no-follow reads and atomic/fsynced writes. The sender does not acknowledge operator notices. Failures stay retryable; receiver-side idempotency is required for duplicate suppression. No real destination, scheduler or message has been configured or sent. The strict release checker now requires exact-candidate receiver acceptance before this feature may be enabled.

## Local verification completed

| Check | Current result |
| --- | --- |
| API / auth, Node 22 Docker | 964 API passed; 309 auth passed; two opt-in API database cases passed separately |
| Database/tool / backup / deployment | 149 unit cases, 45 backup/setup and 22 deployment cases passed; subsets overlap service suites |
| Flutter app / console / shared domain | 1,595 / 31 / 227 passed |
| Analysis / console web build | App: zero errors/warnings, 72 existing infos; console: no issues; CSP release build passed |
| Native Android isolated component harness | Three checks passed on the API 37 arm64 emulator; test package absent after Flutter cleanup; generated build output removed |
| PostgreSQL | Complete 14-script/15-database PostgreSQL 18 harness; OTP replacement and maintenance-reader checks repeated in Docker PostgreSQL 17 |
| Recovery | Paired encrypted v5 migration/export/independent restore/schema/ACL/key verification passed with synthetic data |
| Images / advisories | Exact API/auth images built, 88/58 source files matched/readable as UID 1000; zero known advisories in locked production dependencies at check time |
| Alert adapter | 17 fake DNS/HTTPS/state/TLS/identity cases passed; no actual alert was sent |
| Preserved work | All twelve notification hashes unchanged; original live data and keys were not changed |

Test subsets overlap; do not sum the counts. Temporary Docker database containers and native test build output were removed. Source is still uncommitted on `dev`; no push or deployment occurred. Strict release readiness remains false for the operational and native source/acceptance requirements below.

## Native Android verification scope

A separate temporary Android debug package, `app.pandapay.securityfixture.pandapay`, exercises exact source copies of the SQLite database, receipt snapshot/reconciliation and recovery crypto components. Its integration entrypoint does not initialize the application, real accounts or providers. The tests cover an independent isolate’s writer denial during the native lease, confirmed rollback and normal writes, commit/reopen persistence, and conservative receipt cleanup with another namespace’s reference and an untouched gallery original.

This harness is distinct from the normal installed application. It does not prove full app/plugin packaging, production signing, hardware-backed key custody, process termination/power-loss behavior or native iPhone recovery. Device discovery also found an iPhone, but no app was installed on it by this batch.

## What still prevents “everything is done”

| Work | Remaining requirement |
| --- | --- |
| Live device storage protection | Native key custody, resumable SQLite/receipt encryption conversion, full writer inventory and signed-device fresh/upgrade/offline/key-loss/process-death/low-disk tests. New local encryption remains disabled. |
| Actual-data/privilege cleanup | Review complete current restored-copy privilege/data reports, approve exact grants/maps, preserve all financial/history invariants, and rehearse target upgrade and post-write failback. Synthetic proofs cannot replace this. |
| Operating jobs and alerts | Approve retention policy, replace historical cron in a fenced activation, configure the actual scheduler/independent missing-heartbeat monitor and receiver, then verify delivery/idempotency/resource budgets. Customer notification outboxes remain separate work. |
| Providers and supported clients | Real email/SMS/Google delivery, console cookie/CSP/proxy/operator acceptance, current and oldest supported clients, and monitored retirement of old routes. |
| Recovery custody | Two independent off-host encrypted backup/journal copies, a separately retained latest checkpoint and separate recovery-key custody. One Mac and its shortcut are one location. |
| Release | Exact candidate configuration/evidence, free-host quotas/connection budgets, controlled live rollout and rollback/failback acceptance. Strict release readiness stays false. |

The source changes and synthetic checks do not authorize feature activation or deployment. The full security plan remains open until these source and operational requirements are complete.
