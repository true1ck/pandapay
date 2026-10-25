# Support ticket request bounds — 25 October 2026

This is a narrow source-hardening slice for the post-merge `/support-tickets` route. It keeps the existing four ticket kinds, response shape, PostgreSQL schema, stored rows, and signed-out feedback flow.

## Changes

- The route is extracted into `api/src/support_tickets.js` so its production handler and admission behavior can be exercised directly.
- Request validation rejects malformed payloads before opening a database transaction. Messages are trimmed and capped at 4,000 characters; `appVersion` is optional and capped at 64 characters.
- Diagnostics remain optional, flat JSON objects. The API accepts at most 24 scalar fields, keys up to 64 characters, string values up to 512 characters, and 4 KiB total serialized JSON. Nested objects/arrays and non-finite numbers are rejected. The current mobile callers send compatible scalar diagnostics.
- The existing anonymous route remains enabled because the settings screen supports signed-out OTP troubleshooting. The app field now enforces the same 4,000-character message limit.
- A process-local bounded limiter allows 5 submissions per authenticated profile and 30 per anonymous source IP during a one-hour window. Its in-memory map is capped at 50,000 identities; limited responses include `Retry-After` and HTTP 429. It stores no IPs in PostgreSQL or logs.
- Database write errors keep the existing generic response and log only a safe error code. No request text or diagnostics are logged.

## Verification

The initial bounds batch's focused Node test file covers malformed and oversized requests, the current flat mobile diagnostics, anonymous route registration and insertion, profile/IP rate limits, retry headers, map capacity and window expiry. Its full API suite passed **1,114 tests with two skips and no failures**. The signed-out feedback form regression passed **1 test**, and the API syntax check passed. See [that batch's scoped verification](../artifacts/security-support-ticket-bounds-2026-10-25/verification.json).

## PostgreSQL row-policy follow-up

A later local PostgreSQL fixture reproduced a failure missed by the mocked database tests: `INSERT ... RETURNING` needs the ticket's SELECT policy, which deliberately excludes anonymous rows. The restricted runtime role received PostgreSQL error `42501` and the API returned 500 for signed-out help submissions.

The handler now generates the UUID and response timestamp with scalar database functions inside the existing transaction, then inserts without `RETURNING`. The insert uses the same transaction's `now()` and explicitly starts the ticket in `pending`. The 201 response retains `id`, `kind`, `state` and `created_at`; it does not read stored anonymous tickets or expand any policy/grant.

`node api/test/support_tickets_postgres.js` owns and removes a temporary loopback cluster with synthetic data. It applies migrations 0001–0011, 0016, and the exact ticket/report policy section of `20261024223000_support_tickets_dashboard_and_feedback.sql`; the unrelated dashboard view and later application schema are outside this fixture. PostgreSQL **18.4** passes nine scenarios: the old RETURNING query is refused, anonymous submission works, anonymous reads are denied, member submission works, members see only their own tickets, pooled identity resets, foreign-profile inserts are denied, historical rows are preserved, and operators can triage all tickets. The current API suite passes **1,114 tests, two skips, zero failures**. [Follow-up verification](../artifacts/security-support-ticket-rls-2026-10-25/verification.json).

This proves the source-policy behavior in the disposable fixture. Current-data upgrades, full runtime-role acceptance and hosted PostgreSQL 17/provider acceptance remain open.

## Limits and rollout

The limiter is per Node process and is not shared across replicas or restarts. Its bounded map and per-identity quotas reduce accidental/repeated abuse; they do not establish a distributed abuse budget or launch capacity. Add and exercise a shared edge or database-backed admission control before unrestricted high-volume onboarding. This batch adds no schema migration and changes no live data or service. No audit finding or launch gate was closed.
