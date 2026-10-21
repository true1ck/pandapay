# SMS Intelligence — Phase 5 Report (Gemini Queue)

## Current verification correction (21 October 2026)

This supersedes the earlier single-item and server-side Needs Review descriptions below. The server now has an adaptive 1–4 SMS Gemini worker, shared database-backed RPM/estimated-TPM reservations, bounded retries, and lease heartbeat renewal while waiting for capacity. Failed or uncertain messages remain in the device-owned Needs Review queue; the server does not create a duplicate raw-text review row. The current complete API suite reports **622 total: 621 passed, 1 real-database test skipped**. The migration, `app_user` RLS behavior, provider 429 path, and Flutter tests were not live-verified in this environment.

The worker’s “done” status means the typed facts were accepted and evidence-validated. It does not mean every financial fact became a transaction or bill. Uncalibrated posted-movement and bill facts remain reviewable in the existing app screen; only supported safe projections clear review.

**Date:** 2026-10-21
**Scope:** Durable single-item Gemini job queue, lease-based worker scheduling, rate/token/quota gates, automatic payload check, per-item structured validator, body purging, and mobile queue integration.

## Changed files

| File | Change |
|---|---|
| `db/supabase/migrations/20261021210000_ai_jobs.sql` | Migration defining `ai_jobs` (profile_id, source_id unique, queued/leased/done/failed statuses, payload purged on completion), `ai_events` (redacted append-only job timeline), and `ai_quota_days` (daily per-user budget tracker). RLS owner policies and `app_user` grants. |
| `api/src/gemini_queue.js` | Core queue engine: `acceptOneJob` (sensitive payload check, duplicate suppression via `source_id`, daily quota check, atomic accept), `leaseNextJob` (fair ordering, lease expiry, bounded attempts), `completeJobWithResult` (per-item validation, only empty slots filled, device facts/overrides win, body purged), `failJob` (surfaces in `needs_review_items` before payload purge), `releaseForRetry` (re-queues under same job identity). |
| `api/src/ai_queue_route.js` | REST routes: `POST /ai/jobs` (authenticated app entry point), `POST /ai/jobs/lease` (worker bearer-token lease), `POST /ai/jobs/:id/result` (worker result submission), `POST /ai/jobs/:id/retry` (worker retry release). Guarded by `AI_WORKER_TOKEN`. |
| `api/src/index.js` | Registered `registerAiQueueRoutes` on the Express application. |
| `app/lib/data/user_cards_repository.dart` | Added `submitAiJob({sourceKey, sender, body, occurredAt})` making non-blocking calls to `POST /ai/jobs`. |
| `app/lib/app/providers.dart` | Wired `onSmsUploaded` unresolved handler (`needs_review` or `unparsed`) to invoke `repository.submitAiJob(...)` without blocking local capture, intake acknowledgement, or review queue presentation. |
| `api/test/gemini_queue.test.js` | 14 integration tests covering replay safety, sensitive field refusal, quota exhaustion, crash re-lease, attempt budget overflow to review, empty slot filling, user override priority, cross-user isolation, and worker auth. |

## Evidence

- **Server tests:**
  - `node --test api/test/gemini_queue.test.js`: **14 passed / 0 failed**.
  - `npm --prefix api test`: **558 passed / 0 failed / 1 skipped** (full suite green).
- **Mobile tests:**
  - `flutter test test/data/sms_capture_pipeline_test.dart test/data/local_first_sms_test.dart`: **10 passed / 0 failed**.
  - All SMS capture, scanner, and outbox test suites pass with zero regressions.

## Compatibility gates

| Gate | Status |
|---|---|
| Replay idempotency & no duplicate job or event | ✅ Verified: Repeated `acceptOneJob` returns existing jobId (`reused: true`), one quota unit, one event. |
| Crash / 429 / timeout recovery | ✅ Verified: Re-leases same job ID after expiry; attempts increment; 429 retry release preserves job identity. |
| Failed items reach Needs Review | ✅ Verified: `failJob` inserts into `needs_review_items` before purging body payload. |
| Cross-user isolation | ✅ Verified: Target source is strictly bound to the job row; cross-user redirection rejected. |
| Truthful data handling & body purge | ✅ Verified: On completion or failure, `payload` is set to `{"purged": true}` so raw text does not linger on server. |

## Risks / Next

- Phase 6: Learning and Admin — rule clustering, candidate template evaluation, versioned rule distribution, and read-only monitoring console endpoints.
