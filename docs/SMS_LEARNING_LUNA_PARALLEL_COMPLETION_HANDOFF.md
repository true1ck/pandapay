# SMS learning: Luna parallel completion handoff

**22 October 2026.** This is an implementation handoff, not a completion claim. Read [the final autonomous plan](SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md), [the compatibility audit](sms-existing-flow-compatibility-audit.md), and the current working tree before editing. Preserve all existing changes; several fixes from the latest review are uncommitted.

## Current verified state

- The capture, receipts, canonical facts, Gemini fallback, downloaded global bundle, and existing Needs Review UI already exist. Preserve their behavior and layout.
- This working tree adds a scheduled learning worker runner, stricter holdout selection and lock handling, consent deletion lineage, an additive migration, and a durable mobile dismissal outbox. These changes need integration and full verification.
- **Implemented in this working tree:** candidates are assigned stable `shadow`, `limited`, `expanded`, and `active` deliveries; devices cache and execute assigned candidates, persist one privacy-safe exposure per source, and upload it with the normal lifecycle. Corrections/dismissals mark exposure outcomes, and the worker aggregates them for staged promotion and active-rule rollback. This still needs real PostgreSQL migration/RLS verification before release. Do not simulate exposures or lower gates to make promotion pass.
- The latest full API run before its test expectation was corrected had 710 passed, 1 failed, 2 skipped. The corrected focused learning test passes 8/8; rerun the full suite. A full Flutter run was still running at handoff. Real PostgreSQL tests and Docker were unavailable in that run; do not claim live database verification from unit tests.

## Parallel agent ownership

Luna is the integration owner. Spawn at most three agents with distinct files and ask them to report concrete commits/diffs, tests, and risks. They share one checkout, so no agent should revert or format another agent's files. Luna owns the shared rule/fact contract and final integration.

### Agent A — database, cohort service, telemetry

Own `db/supabase/migrations/*sms_learning*`, `api/src/sms_rule_bundle.js`, `api/src/sms_facts_route.js`, and new cohort/telemetry API files plus their tests. Coordinate any edit to `sms_autonomous_worker.js` with Luna.

1. Add an additive, reversible schema for candidate cohort assignment and **idempotent per-source exposure** keyed by candidate, profile, source key, and stage. Store stage and bundle/rule version, assignment, timestamps, and safe outcome counts; avoid raw SMS in telemetry.
2. Deliver baseline active bundle to everyone and candidate rules only to stable, authenticated cohorts: shadow 0% execution (server/device comparison only), limited 5%, expanded 20%. Assignment must be deterministic per user/candidate, stable across requests, and independent of SMS content. Shadow evaluation needs real new SMS examples and comparable parser output, not a fake device exposure.
3. Update `stage_metrics` from real exposure events and confirmed user corrections/dismissals. Count an exposure once across retry, first-install scan, listener, and sync. Distinguish a user dismissal of a candidate-induced false financial result from an unrelated dismiss. Provide a missed-financial signal for rules that wrongly ignore a source. No telemetry from non-consenting users should become shared training examples.
4. Preserve active version rollback semantics. On candidate pause or global regression, stop serving its rule; ensure the device receives an explicit rollback even when its cached version is numerically newer. Include old-client behavior in tests.
5. Verify RLS and SECURITY DEFINER boundaries with real PostgreSQL under `app_user`, another user, admin, and the dedicated worker role. Do not use a mock as evidence for RLS. Resolve new migration ordering and legacy nullable `profile_id` deletion behavior.

**Acceptance:** authenticated cohort endpoint never leaks another user's assignment; retries do not inflate exposure; stage counts come from persisted events; a paused rule cannot be delivered; opt-out deletes linked examples and blocks new evidence; migration applies on a clean and upgraded DB.

### Agent B — device rule execution, reporting, durable replay

Own `app/lib/data/local/sms_rule_bundle*`, `app/lib/data/local_sms_parser.dart`, `app/lib/data/local/sms_import_store.dart`, `app/lib/data/local/sms_dismissal_outbox.dart`, `app/lib/data/user_cards_repository.dart`, `app/lib/app/providers.dart`, and focused mobile tests. Coordinate the endpoint response contract with Agent A before coding.

1. Download/cache the cohort-aware signed or checksummed rule envelope, validating all restricted rule fields and minimum client version. Keep the last safe active bundle offline. Candidate rules must never bypass OTP/PIN/marketing safety gates, required field validation, user overrides, or built-in fallback.
2. Evaluate shadow rules without applying their facts; record only privacy-safe comparison evidence. Execute limited/expanded rules only for assigned users. Record a durable exposure/outcome event tied to stable source key and candidate stage, and flush it with the existing retry lifecycle. A repeated scan/listener delivery must not create another event or transaction.
3. Finish the dismissal outbox lifecycle: replay after app restart, login/network restoration, and account switch; never send a former account's event under the new account. User correction remains authoritative over later rule replay.
4. Rule updates should affect future SMS and only targeted unresolved sources if explicitly safe; do not reset Android scan checkpoint or re-import all historical messages. Keep Needs Review UI unchanged.

**Acceptance:** offline start, broken/rolled-back bundle, old API response, duplicate delivery, account switch, crash between local receipt and upload, and opt-out cases have focused tests. Existing first-install scan, listener, facts, bills/balances/subscriptions, and review tests still pass.

### Agent C — worker, evaluation, operations

Own `api/src/sms_autonomous_worker.js`, `api/src/sms_evaluator.js`, `api/src/sms_learning.js`, `api/src/sms_learning_worker_runner.js`, compose/deploy/env examples, admin learning monitoring, and related tests. Avoid shared route/schema edits until Agent A agrees on contract.

1. Wire the dedicated worker and production/staging configuration correctly. Require a least-privilege identity that can read consent-eligible examples and update candidate/bundle state; fail closed if misconfigured. Verify advisory locking across multiple worker processes and clean shutdown.
2. Keep candidate generation narrow. Holdout must be from independent users **after** candidate creation, with negative, security, promotional, and historic regression cases. Leave candidates pending when evidence is insufficient. Never certify based on examples that generated the rule.
3. Consume Agent A's persisted stage telemetry and make `shadow -> limited -> expanded -> active` advance only with the required observation window, independent-user counts, sample size, and family-specific error bounds. Roll back on proven regression; pause on uncertainty or provider outage. Do not allow admin HTTP input to weaken production thresholds.
4. Show candidate state, evidence counts, cohort size, correction/false-discard rates, worker last run/failure, bundle versions, and rollback reason in existing admin UI/API. Admin can monitor or emergency pause but is not needed for routine promotion.
5. Check deploy script/compose syntax and document exact migration, worker URL/secret, start, rollback, and health checks. Do not put a key in docs or logs.

**Acceptance:** two concurrent workers do not publish twice; a worker under `app_user` cannot read all examples; bad secrets/DB identity stop startup; candidate cannot promote with zero exposures; regression removes delivery; global bundle publication is versioned and reversible.

## Luna integration sequence and release gates

1. Freeze the API contract and schema names with Agents A/B/C. Integrate additive migration first, then cohort delivery, mobile execution and telemetry, worker consumption, and admin readouts. Resolve conflicting edits personally.
2. Run `git diff --check`, full API suite, Flutter analyze and full mobile suite, console suite, and migration tests against a real local PostgreSQL with `app_user` and worker roles. Record commands, pass/fail/skip counts, and environment. Fix failures; no "all green" claim with skipped DB gates.
3. Exercise a synthetic full loop: first-install scan and future SMS -> local safety -> unresolved review/Gemini -> consented feedback -> candidate -> independent holdout -> real shadow -> 5% -> 20% -> global bundle -> another user's device; inject correction, false discard, duplicate, offline restart, and rollback. Check typed facts once in transactions, balance-as-of, bill/due date, mandate, subscription, and Needs Review. Keep the UI unchanged.
4. Only after gates pass, update phase reports with verified behavior and list any unavailable external check. Do not deploy or claim production readiness based solely on unit tests. Do not commit unrelated changes made by other sessions.

## Copy-ready prompt for Luna 5.6 High

> Complete the remaining SMS autonomous learning loop in `C:\Users\sujay\CKProjects\PandaPay`. Read `docs/SMS_LEARNING_LUNA_PARALLEL_COMPLETION_HANDOFF.md` and its linked final plan and compatibility audit. Inspect and preserve all current uncommitted work. Spawn three agents with the file ownership and acceptance criteria in the handoff; you own the shared contract and final integration. Implement real cohort delivery, durable device exposure feedback, persisted stage metrics, safe promotion/rollback, and the listed worker, consent, and deployment checks. Do not change the existing Needs Review UI or reset SMS checkpoints. Run full API/mobile/console tests and real PostgreSQL role/migration tests. Report exact results and remaining external blockers. Never mark the loop complete from mocked counters or skipped DB tests.
