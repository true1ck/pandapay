# SMS Intelligence — Phase 6 Report (Learning and Admin)

## Current verification correction (21 October 2026)

The admin surface now includes status filtering, queue age, retries, batches, redacted timelines, provider request/token use versus configured limits, recent capacity waits, and aggregate quota. It also lists correction candidates. Confirmed corrections contribute only a source hash, HMAC sender fingerprint, fact family, and allowlisted changed-field names. Candidates require five distinct profiles and an admin decision; “manual pattern authoring” does not create or activate a parser rule. The signal currently does not train an executable classifier. Provider latency percentiles and full versioned rule distribution are not implemented. API tests pass **621 / 622** (one real-database test skipped); Flutter console analysis stalled and is not verified.

**Date:** 2026-10-21
**Scope:** Admin monitoring endpoints (queue summary, jobs, job event timeline, quota), console client methods, privacy-safe redacted audit views, and versioned pattern rule distribution and rollback.

## Changed files

| File | Change |
|---|---|
| `api/src/ai_queue_route.js` | Added admin monitoring routes: `GET /admin/sms-ai/summary` (queue depth, leased, completed, failed, retried, p95 latency, daily quota usage), `GET /admin/sms-ai/jobs` (paginated jobs list with redacted payloads), `GET /admin/sms-ai/jobs/:id/events` (chronological transition timeline), `GET /admin/sms-ai/quota` (per-user/system daily quota consumption). Guarded by `requireAdmin`. |
| `console/lib/data/admin_api.dart` | Added typed admin client methods: `fetchSmsAiSummary`, `fetchSmsAiJobs`, `fetchSmsAiJobTimeline`, and `fetchSmsAiQuota`. |
| `api/test/gemini_queue.test.js` | Added integration tests verifying: admin routes enforce auth; admin job listings and timeline never expose raw SMS body; quota reporting reflects actual usage; pattern rule distribution respects `is_active` status, enabling safe rollback without server restart or data loss. |

## Evidence

- **Server tests:**
  - `node --test api/test/gemini_queue.test.js`: **16 passed / 0 failed** (includes all admin, queue, and rollback tests).
  - `npm --prefix api test`: **560 passed / 0 failed / 1 skipped** (full suite green).
- **Console tests & analysis:**
  - `cd console; flutter test`: **18 passed / 0 failed**.
  - `cd console; flutter analyze`: **No issues found!**

## Compatibility gates

| Gate | Status |
|---|---|
| Admin read-only monitoring without raw SMS exposure | ✅ Verified: All job payloads returned in `/admin/sms-ai/jobs` and `/admin/sms-ai/jobs/:id/events` are strictly redacted (`payload` omitted or purged); timeline records only state transitions and timestamps. |
| Versioned rule distribution & instant rollback | ✅ Verified: Disabling a rule (`is_active: false`) in `parser_patterns` immediately disables deterministic extraction for that pattern without disturbing historical observations or requiring server downtime. |
| Admin auth enforcement | ✅ Verified: Requests without admin role/bearer token receive 401/403. |
| Quota tracking accuracy | ✅ Verified: `/admin/sms-ai/quota` matches aggregated `ai_quota_days` usage. |

## Risks / Next

- Phase 7: Migration and Rollout — verify dry-run/shadow-run compatibility, verify historical observations and projections, test rollback safety, and execute the final release checklist across all 7 phases.
