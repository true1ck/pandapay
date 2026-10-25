# Gemini SMS pilot admission gate — 25 October 2026

## Finding

The merged production compose file set `ENABLE_SMS_AI_QUEUE=true` by default. The `/ai/jobs` route treated that process-wide value as an unconditional bypass of the database master and per-profile rollout flags. The merged `20261025100000_enable_sms_ai_queue.sql` migration also set the AI queue to 100% rollout. As a result, the documented 1% pilot and the pause workflow's database flag could be bypassed when worker credentials were configured.

## Source change

- `/ai/jobs` now always checks `sms_facts_pipeline_enabled` and `sms_ai_queue_enabled` in PostgreSQL and applies the deterministic profile cohort. The environment-variable bypass is removed.
- Production compose no longer sets the bypass variable.
- A new forward-only migration, `20261025232400_pause_gemini_sms_queue_until_pilot.sql`, upserts the AI queue flag to disabled with 0% rollout. It leaves the general SMS facts master flag and existing queue/user rows unchanged. The older migration remains intact for migration-history compatibility.
- The existing explicit pilot workflow remains the only route to enabling a cohort; it sets the database flag to 1%. The pause workflow now effectively prevents new submissions because the API honors that database flag.

The control is source-only until the migration is applied and matching API code is deployed. It prevents new submissions; already accepted queue rows are preserved and may still be processed by the worker. No database migration, provider request, message processing, data deletion or deployment occurred in this batch.

## Verification

- `api/test/gemini_queue.test.js`: **36 passed**. The disabled-flag regression sets the old override to `true` and verifies that no job is admitted or stored; the existing deterministic 1% cohort case still passes.
- `db/tests/migration_prefix_policy.test.js`: **5 passed**.
- `node --check api/src/ai_queue_route.js`: passed.
- Release-source candidate SHA-256: `0a4ad3c32aa4e2b9405c556f51a931b4116e822b62baf4e8147541ef42b08dd4` (1,399 files).
- [Verification summary](../artifacts/security-ai-pilot-gate-2026-10-25/verification.json).

No finding count is closed by this fix. Provider entitlement, the full post-merge audit, actual database migration acceptance, app/API full-suite regression and production rollout remain open.
