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

The focused Node test file covers malformed and oversized requests, the current flat mobile diagnostics, anonymous route registration and insertion, profile/IP rate limits, retry headers, map capacity and window expiry. The full API suite passes **1,114 tests with two skips and no failures**. The signed-out feedback form regression passes **1 test**, and the API syntax check passes. See [the recorded scoped verification](../artifacts/security-support-ticket-bounds-2026-10-25/verification.json).

## Limits and rollout

The limiter is per Node process and is not shared across replicas or restarts. Its bounded map and per-identity quotas reduce accidental/repeated abuse; they do not establish a distributed abuse budget or launch capacity. Add and exercise a shared edge or database-backed admission control before unrestricted high-volume onboarding. Existing tickets and all database rows are untouched. No migration was added or run, no provider or production service was contacted, no deployment occurred, and no audit finding or launch gate was closed.
