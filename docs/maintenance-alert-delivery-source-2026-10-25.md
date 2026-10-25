# Maintenance alert delivery source slice (2026-10-25)

This document describes an optional source-side adapter for the existing
`maintenance.read_notifications()` function. It does not activate maintenance
jobs, configure a host service, or establish that any receiver exists.

## Current behavior

Run `node db/scripts/maintenance_alert_delivery.js` from the repository to get
a configuration diagnostic dry-run (no database counts are fetched). This mode does not connect to PostgreSQL or the network.
The opt-in invocation is `node db/scripts/maintenance_alert_delivery.js
--send` and fails closed unless `MAINT_ALERT_DELIVERY_ENABLED=true` is set.
No environment file is read by this implementation. A deployment would need
to provide the following separately, without committing secrets:

- `MAINT_ALERT_READER_DATABASE_URL`: a dedicated maintenance-reader login URL
  using the shared strict TLS resolver; certificate and hostname verification cannot be replaced by URL options. Optional `MAINT_ALERT_DB_SSL_CA` or `MAINT_ALERT_DB_SSL_CA_FILE` adds reviewed CA trust. Query, statement, connection and overall database-read budgets are bounded. The actual login must pass the narrow maintenance-reader identity checks.
- `MAINT_ALERT_WEBHOOK_URL`: one HTTPS webhook URL without userinfo, query, or
  fragment.
- `MAINT_ALERT_WEBHOOK_HOSTS`: comma-separated exact permitted hostnames.
  DNS answers are checked and pinned for the request; all must be public.
- `MAINT_ALERT_SOURCE_ID`: stable non-secret installation identifier (16–64 letters/digits/underscores/hyphens). Retain it and its delivery state when moving the same database to another host. Distinct installations need distinct IDs.
- `MAINT_ALERT_DELIVERY_STATE`: required absolute canonical path to the private delivery-state file. Its existing containing directory must be a real, owner-only private directory (mode 0700); the state file is mode 0600. The state is source-bound, bounded, no-follow read and atomically/fsynced replaced. State persistence is preflighted before sends.

The source reads only `maintenance.read_notifications()` and never calls
`maintenance.acknowledge_notification()`. Its JSON request contains only the
fixed job name, notification code, generation, and occurrence count. It omits
timestamps, paths, SQL, contacts, errors, and credentials. Batch size is at
most 12, request timeout is at most 2.5 seconds, and the send admission budget is 8 seconds (plus at most a 5-second database-read budget). In-flight HTTPS requests have a wall-clock timeout, validated DNS addresses are pinned, redirects are refused and response bodies are closed immediately. The persistent local state tracks at most 12 `(job, code)` identities
and is atomically replaced after successful webhook responses. Failed or
uncertain responses remain eligible for retry with the same stable
`Idempotency-Key` bound to source/job/code/generation; a receiver must honor that key. This is not an exactly-once
delivery guarantee.

The source validates all four fixed jobs, including separate auth retention, and all three fixed notification codes in the migration. Acknowledged rows are skipped.
This adapter does not change recovery behavior, database schema, lifecycle
flags, or job enabled defaults.

## Acceptance still pending

| Area | State |
| --- | --- |
| Source implementation and local fake-transport unit tests | Present |
| Actual deployment host, service identity, and private state path | Pending |
| Receiver ownership, TLS certificate, and exact allowlisted hostname | Pending |
| Receiver idempotency-key behavior and alert acceptance evidence | Pending |
| Operational alert routing and on-call acceptance | Pending |
| Any live credential, destination, or external request | Not configured or performed |

Do not enable this adapter until the deployment host and receiver have passed
their own security and acceptance review. That review must verify hostname
ownership, verified TLS, receiver-side idempotency, and that the receiver does
not require or log additional sensitive fields.

## Operational boundary

This adapter does not install a host scheduler or detect a host that never invokes it. An independent monitor must check missing/late executions. It never acknowledges an operator notice automatically. Sending failures produce a nonzero exit and count-only diagnostics; raw database, destination and transport errors are not printed. New `MAINT_ALERT_DELIVERY_ENABLED` accepts only `true`/`false` and remains false/unset. The strict release checker requires separate exact-candidate receiver acceptance before enablement.

The delivery state is private local metadata, not a cryptographically authenticated source of truth. Preserve it during provider migration to avoid duplicate notices; restoring an older database/state can change delivery history. Parallel runs and crashes can retry an already accepted event, so receiver idempotency remains required. Fake DNS/HTTPS/SQL tests prove local control behavior only; actual recipient delivery and TLS/proxy/free-host behavior remain pending.
