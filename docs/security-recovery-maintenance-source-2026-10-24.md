# Recovery, maintenance and permission repair — 24 October 2026

This continues the [follow-up](security-followup-implementation-2026-10-24.md) on the existing dirty `dev` branch. [Current local verification](../artifacts/security-local-docker-verification-2026-10-24/batch-verification.json) records the completed Docker, Flutter and database runs. The preceding [partial source verification](../artifacts/security-implementation-2026-10-24-completion-source/batch-verification.json) remains a historical record. **This source is not release approved.** No live database, account, credential, provider, scheduler or service was changed. New feature flags remain off. Original keys, UUIDs/history and all twelve notification edits are preserved.

## Latest follow-up

The [25 October follow-up](security-next-implementation-2026-10-25.md) adds opt-in six-digit verified contact replacement, bounded DB-aware reconciliation of journaled recovery receipts and a disabled operational webhook adapter with its own release gate. [Current evidence](../artifacts/security-followup-2026-10-25/batch-verification.json) records the combined local verification; the [preceding Docker batch](security-local-docker-verification-2026-10-24.md) remains historical. Supported-client/provider acceptance, native key custody/resumable live storage encryption, complete native crash/writer coverage, actual-data/provider reconciliation, monitored operations and independent recovery custody remain open. No live configuration, data, key, contact, provider or deployment change occurred.

## Current source and verification boundary

| Area | Added source | Required before activation |
| --- | --- | --- |
| Six-digit client transition | Mobile login/account recovery and native/browser console clients carry exact device/contact/purpose/challenge bindings. Fields, code boxes and autofill support six digits. Browser gateway relays only bounded v2 metadata and keeps bearer credentials server-side. | Local current-source app/auth/console regressions passed. Real delivery and supported-client/browser acceptance remain. |
| Compatibility retirement | `AUTH_RETIRE_LEGACY_OTP` and `AUTH_RETIRE_PUBLIC_LOOKUP` explicitly retire old OTP or anonymous lookup with uniform `410 client_update_required`. Trusted v2 routing and refresh remain. Both flags default false. | Accepted supported v2 clients, preserved masked-email recovery, monitored compatibility window and exact-candidate retirement proofs. The 25 October follow-up also adds compatible opt-in six-digit contact replacement; explicit legacy OTP retirement now covers its old endpoints. Actual supported-client acceptance remains required. |
| Account data recovery | Manual consent UI, existing-factor verification, create/list/discard, optional receipts, and fresh-account restore before login publishes the session. No new password or automatic upload. | Local app/SQLite/HTTP regressions passed. Native process-death/low-disk/account-switch and signed-device acceptance, measured free-host quotas and accepted key custody remain. Live database/receipt encryption remains off. |
| Local operation fence | Native separate-connection `BEGIN IMMEDIATE` lease, ordinary same-isolate connections made query-only, sync/SMS/outbox/receipt/network admission and drain, separate bounded durable SMS deferral spool. | Full concurrent writer and supported background-isolate/device matrix. These mechanisms do not prove coverage of arbitrary native/file writers or abandoned async work. |
| Operational maintenance | Disabled private job controls, bounded product runner, separate auth retention coordinator, durable leases/cursors/heartbeats, bounded internal failure notices with generation acknowledgements, optional one-shot Compose profile. | Local migration/effect/role fixtures and whole paired recovery passed. Approve retention policies, review old cron replacement, then install/monitor the actual scheduler and alert delivery. |
| Wider permissions | Explicit reviewed grant-removal plans, source/catalog/policy/target binding, rollback-only rehearsal, fresh receipt required for apply, effective-access and object-definition comparisons. | Current actual-data restored-copy review, complete application/provider matrix, exact repository policy and final target-role acceptance. Unmodelled PUBLIC/ownership/RLS/membership/definer repairs stay blocking. |

The [local Docker verification](security-local-docker-verification-2026-10-24.md) now records fresh current-source results: 964 API passes (two database cases passed separately), 300 auth, 131 database/tool, 45 backup/setup, 22 deployment, 1,576 app, 31 console and 227 domain cases. Four current security fixtures passed on Docker PostgreSQL 17; the complete 14-script/15-database harness and paired encrypted v5 recovery passed on temporary PostgreSQL 18. Exact images, non-root source readability, both services’ real health/readiness, console CSP build and zero-known-vulnerability dependency audits passed. Earlier approval-review usage failures have been resolved for these local runs. Flags remain off; actual-data/provider/browser/signed-device/custody acceptance and deployment remain pending. Original keys/data and all twelve notification edits are preserved.

The local startup check fixed an auth container default-port mismatch. Test portability fixes align the macOS checksum preflight, temporary function-owner schema grants, and SMS fixture profile seeding with the actual security contracts. No application runtime grant was broadened.

## OTP configuration and behavior

Build mobile/console with `--dart-define=PANDAPAY_OTP_V2_ENABLED=true` only after auth migration `0011_versioned_otp_challenges.sql` and gateway/service acceptance. The default is false, preserving current clients. V2 request metadata is validated; a missing/expired/foreign challenge or wrong device/contact/purpose is refused locally. The server separately verifies every binding and expiry. No 404, malformed response, network error or old four-digit code causes an automatic downgrade.

A v2 email request sends email/device only; sign-up phone claims are not used to select an identity. The separate verified-contact flow must establish phone ownership. Console v2 uses recovery-only authentication so a public console request cannot create an account. Console device/challenge binding stays stable for that sign-in attempt; browser tokens remain in the HttpOnly gateway session.

The retirement flags accept only `true` or `false`. They stay false in tracked examples and Compose. The release checker requires matching feature manifests and supported-client/proof-only lookup acceptance for retirement. Supported older clients must be handled before a flag is enabled. Existing masked contact recovery continues behind factor verification.

## Password-free recovery integration

`PANDAPAY_ACCOUNT_RECOVERY_ENABLED` is a compile-time opt-in, false by default. The backend `ACCOUNT_RECOVERY_ENABLED` and database control also remain off. The new screen is linked from Sync & backup when enabled; create/list/discard uses recent existing email/phone OTP. Recent signed-in factors or a page-memory proof may be reused as a UI convenience, while the backend independently verifies current account/device and its five-minute proof window on every request. Recovery verification never replaces durable login credentials or logs out the current device.

Create requires explicit pending-data consent. Receipts are independently optional. It captures only the exact `user:<UUID>` namespace, original mutation IDs and pending work, then encrypts, uploads, downloads/decrypts and verifies. The complete capture includes only data at its snapshot point; later changes require another manual copy. The existing 5 MiB/archive, two copies/account, global/physical quota and cooldown limits still apply. Refusal preserves previous copies. There is no new user password or key-file prompt.

Fresh-device restore is offered after OTP verification and before publishing `accessTokenProvider`, avoiding normal account cache/sync hydration before restore. It never clears or relabels an existing populated namespace. The user can continue signing in without restoration; a failed restore does not remove that option. Restore preserves IDs and resets in-flight state for idempotent replay. A receipt path is private and independently generated; source gallery files are never cleanup targets.

The operation gate drains tracked foreground async jobs. A native SQLite writer lease separately blocks independent/background writers; same-isolate ordinary connections are query-only so a callback cannot accidentally join the recovery transaction. Receipt changes and authenticated HTTP response consumption are tracked. On close, HTTP admissions are released; uncertain SQLite commit/rollback preserves newly installed files until DB-aware reconciliation rather than risking deletion of a committed receipt. This needs native crash and orphan reconciliation acceptance before activation.

SMS arriving during the fence is durably deferred in `pandapay-recovery-deferred-sms.sqlite` beside the ordinary DB, with namespace/source IDs. It never evicts old unsent messages: at most 200 messages and 1 MiB logical sender/body storage. Draining commits to normal idempotent intake before acknowledging the spool. It remains local plaintext under the existing native storage boundary while live storage encryption is disabled. Inbox reconciliation remains necessary for delivery/low-disk failures. Independent native file writers and untracked async work require review; the gate alone is not proof of universal application quiescence.

## Bounded operational maintenance

New additive product migration: `20261024111632_bounded_operational_maintenance.sql`, generated with the installed Supabase CLI. It creates private RLS/forced-RLS `maintenance.jobs` and `maintenance.notifications`, fixed empty-search-path functions and separate NOLOGIN owners/capabilities. All jobs start disabled. Temporary migration-owner SET/INHERIT grants are restored; runtime logins never receive control-table or customer-table access.

Fixed jobs:

- `merchant_confidence`: bounded UUID cursor rotation, existing contribution/recency thresholds, no customer financial reads.
- `rate_divergence`: bounded summary claims and existing policy-alert/evidence writes, atomically marks each processed summary.
- `inbound_body_retention`: optional body-only scrubbing after both original expiry and an explicit 30–3650 day policy. Policy-hit bodies, all mail IDs/metadata and financial/identity history remain. Unset policy cannot enable this job.
- `auth_retention`: product ledger lease/heartbeat only; actual auth DML uses the existing separately configured diagnostic/expired-abuse policy and a different auth maintenance connection. No security audit, account, OTP or financial purge.

Per job: 1–100 rows/batch (default 25), 60–86400 second interval, 90-second lease, durable generation/cursor and count-only progress. Product runner processes one batch of each of its three jobs per invocation, with a 15-second admission budget; continuation yields for at least 60 seconds. Dedicated connections have statement/lock/query timeouts and are closed after uncertain outcomes. Auth adapter caps work at 100 rows/batch, 10 batches and 5 seconds. Peak product coordinator plus auth DML uses two separate connections; include these and the product runner in the measured total host budget.

There are at most twelve internal notice rows (four jobs × three fixed failure codes). Repeated events increment counts/generations; acknowledgements require the current generation. Only the reader/operator capability can acknowledge. This is an internal operational outbox; no external message transport or delivery is configured by this batch. A scheduler that is stopped cannot report its own lateness, so independent heartbeat/alert delivery must be accepted on the actual host.

Optional migration bootstrap credentials, all blank by default: `MAINTENANCE_DB_PASSWORD` → `maintenance_runtime`/`pandapay_maintenance`; `AUTH_MAINTENANCE_DB_PASSWORD` → `auth_maintenance_runtime`/`pandapay_auth_retention_coordinator`; `MAINTENANCE_READER_DB_PASSWORD` → `maintenance_reader_runtime`/`pandapay_maintenance_reader`. Existing passwords are preserved on replay. Auth DML maintenance grants require their separate reviewed policy and narrow identity; a product coordinator URL cannot substitute for it.

Operator commands, using protected process configuration rather than command-line secrets or implicit `.env` loading:

```sh
# Product: default bounded status/notice report, no job effects.
node api/src/maintenance/cli.js
# Explicit source entry points after policy/role/migration acceptance.
node api/src/maintenance/cli.js --run
node auth/src/services/maintenanceCli.js --run --apply
# Optional, one-shot deployment commands; no host scheduler is installed.
docker compose -f docker-compose.prod.yml --profile maintenance run --rm --no-deps operational-maintenance
docker compose -f docker-compose.prod.yml --profile maintenance run --rm --no-deps auth-retention-maintenance
```

`MAINTENANCE_ENABLED=false` and `AUTH_RETENTION_MAINTENANCE_ENABLED=false` remain defaults. Separate `MAINTENANCE_DATABASE_URL`, `AUTH_MAINTENANCE_DATABASE_URL`, `AUTH_RETENTION_DATABASE_URL` and verified TLS/CA configuration are required for the enabled paths. The release gate adds exact-candidate maintenance/scheduled-retention acceptance. The profile uses non-root images, read-only container filesystems, dropped capabilities, 128 MiB and 64 PID limits.

**Existing cron is preserved by additive schema.** During a separately reviewed fenced activation, replace the three historical schedules (`purge-inbound-emails`, `recompute-merchant-confidence`, `detect-rate-divergence`) with accepted bounded jobs and approved policy. Disable the superseded entries in that same controlled step; do not leave both systems active or silently stop working jobs merely by deploying new schema. Current original cron behavior remains an open finding until that activation is completed.

## Reviewed permission repair

```sh
node db/scripts/runtime_privilege_repair.js inspect --scope product > /protected/inspection.json
# Fill and review the returned review_template; never add raw credentials.
node db/scripts/runtime_privilege_repair.js plan --inspection /protected/inspection.json --review /protected/review.json > /protected/plan.json
node db/scripts/runtime_privilege_repair.js rehearse --plan /protected/plan.json --quiesced > /protected/receipt.json
# Only for the same exact reviewed target/catalog/source after all acceptance:
node db/scripts/runtime_privilege_repair.js apply --plan /protected/plan.json --receipt /protected/receipt.json --quiesced
```

Use explicit protected `PRIVILEGE_REPAIR_DATABASE_URL` and `PRIVILEGE_REPAIR_DB_SSL`/CA settings. For auth inspection, also pass the actual `--scope auth --runtime-role ROLE` (repeat for each reviewed login). Inspect/plan are read-only; rehearsal always rolls back. Apply requires a fresh 24-hour exact-plan receipt, the same target/original grantor, current catalog, repository policy and source hash, plus quiesced acknowledgement. A source/catalog/policy change requires a new review/rehearsal.

Operations are individually quoted direct ACL removals with `RESTRICT`; arbitrary SQL, CASCADE, ownership, membership, PUBLIC, RLS, unsafe definer rewriting or extension-owned object changes are refused. Exact reviewed effective-access losses must match, no new access may appear, and definitions/owners/roles/RLS stay unchanged. Blocking findings must decrease; unresolved findings remain visible, and a successful targeted repair does not certify the entire schema. Fresh independent-LOGIN fixtures passed on PostgreSQL 18 and Docker PostgreSQL 17, preserving tenant RLS CRUD, a separate safe service RPC and row digests. Actual-data review and intended managed-target acceptance remain.

## Next verification and remaining release work

Current local checks are complete as recorded in the [local verification report](security-local-docker-verification-2026-10-24.md). Ordinary API runs skip two opt-in database cases; both were separately executed successfully against a fresh fully migrated local database. Tests used synthetic data and sanitized source without live `.env`, keys, credentials or providers. Local results do not certify actual target resources, provider delivery or signed devices.

Then complete actual-data privilege/data reconciliation, contact-conflict rollout, supported-client/provider contact-code acceptance, browser/provider/oldest-client acceptance, app/native writer inventory and crash/orphan repair, secure platform key custody/resumable storage conversion, external operational/customer notification delivery, measured free-host limits and intended-provider cutover/post-write failback. Two independent off-host backup/journal locations and separate private-key custody are still required. No live storage encryption, retirement flag or recovery/maintenance activation is approved by source/static checks alone.
