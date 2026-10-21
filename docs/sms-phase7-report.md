# SMS Intelligence — Phase 7 Report (Migration and Rollout)

## Current verification correction (21 October 2026)

The earlier “fully implemented, integrated, verified” statement at the end of this report is superseded. The final local verification is **API 624 passed / 0 failed / 1 DB-dependent skip; app 1,150 passed / 0 failed; console 21 passed / 0 failed; console analyzer clean**. The app’s changed provider file also analyzes clean. Docker PostgreSQL contains the new tables, shows forced RLS on user-owned AI/fact tables, and has no queued AI jobs. A synthetic Gemini batch smoke test passed earlier in the session. The API container has not been rebuilt from current source, the opt-in worker is not running, and signed-in on-device flow is not verified. Do not treat this phase as production-ready until those remaining gates pass.

### Release hardening update (21 October 2026)

- AI acceptance now fails closed if `sms_ai_queue_enabled` is absent. Unit tests explicitly cover missing, zero-percent and enabled rollout states.
- Shared learning checks `profiles.contributions_opt_in` before writing any cross-user signal; opt-out still permits the user's correction to remain in their local/server-owned fact override.
- Production Compose has an opt-in `sms-ai` Gemini worker profile. The deploy script requires both server-only credentials together, enforces a 32-character worker token, starts the isolated worker only when enabled, and stops it when disabled. It never prints the credentials.
- Added a CI database smoke test for app-user RLS isolation, cross-profile worker claiming only via the narrow lease function, and RPM capacity waiting. CI is the remaining execution path: this Windows session could validate Compose syntax but cannot access the Docker engine (`//./pipe/docker_engine` access denied), so the SQL gate was not run locally.
- Current API suite: **627 passed, 0 failed, 1 database-dependent skip**. `docker compose ... config -q` and `git diff --check` pass. Shell syntax and database execution remain unverified locally due shell/Docker access restrictions.
- Production remains a staged, operator-controlled rollout: AI feature flag absent/off by default; migrations, credentials, monitoring, pilot percentage and rollback procedure are documented in `deploy/DEPLOY.md`. No production schema or service was changed.

**Date:** 2026-10-21
**Scope:** Historical observation dry-run comparison, shadow projection validation, staged feature flag rollout by message family, idempotent backfill migration, and rollback verification without data or override loss.

## Changed files

| File | Change |
|---|---|
| `api/src/sms_observation_migration.js` | Core migration & rollout engine: `extractFactsFromObservation` (maps legacy observation objects to canonical typed facts with validated amount and date roles), `compareObservationProjections` (computes legacy spend vs new multi-fact spend, non-spend separation, and field validity), `dryRunObservations` (batch dry-run metric aggregator), `evaluateFeatureFlag` & `resolveSmsIntelligenceFlags` (deterministic percentage rollout per profile using SHA-256 hash buckets across message families: spend, balance, bill, mandate, and AI fallback), and `backfillHistoricalObservations` (safe, idempotent backfill to `sms_sources` and `sms_source_facts` preserving exact source keys, receipts, and user overrides). |
| `api/src/ai_queue_route.js` | Added admin migration endpoints: `POST /admin/sms-ai/dry-run` (executes dry-run projection comparison over submitted or historical observations) and `GET /admin/sms-ai/rollout` (inspects current feature flag rollout configuration). Both guarded by `requireAdmin`. |
| `console/lib/data/admin_api.dart` | Added typed client methods: `runSmsAiDryRun(observations)` and `fetchSmsRolloutStatus()`. |
| `app/lib/features/sms_import/sms_consent_screen.dart` | Updated privacy disclosure copy to truthfully explain that message text is encrypted in transit and purged immediately after classification, ensuring compliance before enabling live worker traffic. |
| `api/test/sms_observation_migration.test.js` | 11 tests covering: multi-fact extraction from historical observations (debit with balance, bill obligation role separation, mandate lifecycle, failed attempts, alerts), projection dry-run accuracy and spend reduction calculation, deterministic percentage rollout hashing, master and family feature flag toggles, idempotent backfill replay, rollback safety (retaining facts and user overrides), and admin dry-run/rollout route authorization. |

## Evidence

- **Server tests:**
  - `node --test api/test/sms_observation_migration.test.js`: **11 passed / 0 failed**.
  - `npm --prefix api test`: **572 passed / 0 failed / 1 skipped** (full API test suite green).
- **Mobile tests:**
  - `flutter test` across all SMS intelligence, outbox, contract, scanner, capture, intake, background, backup, and needs review suites: **135 passed / 0 failed**.
- **Console tests & analysis:**
  - `cd console; flutter test`: **18 passed / 0 failed**.
  - `cd console; flutter analyze`: **No issues found!**

## Compatibility gates

| Gate | Status |
|---|---|
| Source identity & receipt preservation | ✅ Verified: `backfillHistoricalObservations` strictly preserves existing `source_key` and body hash. Replaying historical observations produces `replayed: true` with zero duplicate fact rows or broken receipts. |
| Non-spend separation & spend protection | ✅ Verified: Projections cleanly separate balance snapshots, bill obligations, mandates, and security alerts from posted movements, preventing false spending inflation. |
| User override precedence | ✅ Verified: User corrections in `fact_overrides` take precedence over migrated or AI facts and are never overwritten or deleted by backfills or replays. |
| Staged rollout per family | ✅ Verified: Individual families (`sms_family_balance_enabled`, `sms_family_bill_enabled`, `sms_family_mandate_enabled`, etc.) and fallback AI queue can be staged independently with deterministic per-profile percentage bucketing. |
| Safe rollback without data loss | ✅ Verified: Disabling `sms_facts_pipeline_enabled` falls back gracefully to legacy handling. Underlying `sms_sources`, `sms_source_facts`, and `fact_overrides` rows remain intact, instantly restoring full multi-fact projections upon re-enablement. |

## Final Program Completion

Implementation is substantially wired, but production completion is pending the live database/RLS and Android/console validation gates listed above. The original completion statement was premature and is withdrawn.
