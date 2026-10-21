# SMS intelligence review and Luna 5.6 implementation handoff

Reviewed 21 October 2026 against [the master implementation plan](SMS_INTELLIGENCE_MASTER_IMPLEMENTATION_PLAN.md), [the existing flow audit](sms-existing-flow-compatibility-audit.md), and the working tree. This is a review of the current implementation, not a completion report. Preserve all existing uncommitted work and inspect `git status` before editing.

## Verdict

The existing automatic SMS capture and transaction path remains present, and the new typed fact intake has useful groundwork. The planned system is **not yet end to end**. The implementation has a single-job Gemini worker and an initial admin operations view, but AI results still do not cover every current product projection, the existing Needs Review page does not yet reconcile completed server jobs, and microbatching/learning/rollout controls remain incomplete. Phase reports should be corrected after implementation and verification.

## Current implementation progress (21 October 2026)

This working session has completed the following items without replacing the
legacy SMS path:

- Added an atomic database lease function using `FOR UPDATE SKIP LOCKED`, a
  bounded attempt budget, delayed retry scheduling, lease-token fencing, and
  redacted admin functions for queue, event, and quota views.
- Added the server-side Gemini provider and single-job worker loop in
  `api/src/gemini_worker.js`, including structured JSON prompting, 429/5xx
  retry handling, and a `worker:gemini` launcher.
- Server job payloads now carry a redacted body plus the original body hash;
  completed and failed jobs purge their payload. Failed server jobs no longer
  create a second raw-text Needs Review row because the device already owns
  that review item.
- AI facts now pass through the existing specialist path for due-day and
  mandate/subscription effects, and balance snapshots are included in
  `/account-summaries` with their source timestamp.
- Added a redacted device job-status endpoint and an SMS AI Operations screen
  to the existing admin console.
- Added focused worker tests and updated queue tests; the API suite currently
  reports 579 tests, 578 passed, and 1 skipped. Flutter analysis did not finish
  in this environment and is not reported as passing.

The remaining end-to-end gaps are still material: posted movement projection
from AI facts, adaptive microbatching, device reconciliation of completed AI
jobs into the existing Needs Review screen, shared-learning promotion, live
rollout enforcement, and real `app_user` Postgres integration coverage. These
must be completed before production rollout.

## Findings, ordered by impact

| Priority | Finding and evidence | Required outcome |
| --- | --- | --- |
| P0 | Worker and admin routes use `withUserClient(null)` in `api/src/ai_queue_route.js` (lines 65, 81, 107, 132 onward). `api/src/db.js` says null gives no RLS identity; the new migration forces owner RLS on `ai_jobs`, `ai_events`, and `ai_quota_days`. With the documented non-superuser `app_user` connection, leases see no jobs, result writes cannot work, and admin metrics are empty. Current tests use mocks and do not exercise this DB role. | Implement narrowly scoped, audited worker/admin DB access that works under real RLS. Add integration tests using `app_user` and two profiles. Never set one user's ID while querying another user's data without an explicit privileged design. |
| P0 | No Gemini `generateContent`/provider client or worker loop is present. `api/src/gemini_queue.js` only accepts, leases, stores results and retries through HTTP. There is no adaptive microbatch dispatcher, provider RPM/TPM/day or concurrency gate, Retry-After/backoff, live versus backfill priority, or queue deadline. `releaseForRetry` immediately requeues (around line 192). | Build a deployable Gemini worker with one server-side project key, structured per-job output, small adaptive groups, fair scheduling, bounded provider quota, jittered retries, terminal review routing and observable batch/event records. Start with one job and then the planned small-group experiment. |
| P0 | `completeJobWithResult` in `api/src/gemini_queue.js` (around line 206) writes fact rows but does not run the specialists in `api/src/sms_facts_route.js` or project a posted movement, balance, bill, mandate or subscription into existing user-facing state. `app/lib/app/providers.dart` submits the job and ignores its ID/result (around line 1325). | Route validated AI facts through the same domain writers as deterministic facts. Reconcile completed jobs with the app, refresh the relevant views, and remove/update the corresponding Needs Review item only when a safe result is actually materialized. Preserve exactly-once economic writes. |
| P0 | `app/lib/app/providers.dart` immediately adds unresolved messages to local Needs Review and fire-and-forgets the AI request. `api/src/gemini_queue.js` writes failed jobs to server `needs_review_items`, while `app/lib/data/needs_review_repository.dart` and the existing review screen read an on-device table. Thus server failures do not appear in that screen and accepted results never clear the local item. | Define one durable per-source review state with device/server reconciliation. The existing Needs Review screen remains the only user queue. Offline, 429, invalid output and expiry must leave a reviewable item; successful verified output must update it correctly. |
| P1 | Result route in `api/src/ai_queue_route.js` validates only the fact schema (around line 87). It does not check textual evidence, identity, sign, amount/date role, lifecycle contradictions or calibrated per-field decision gates. The current code has no new scoring or abstention policy. | Add a per-family/per-field semantic validator and measured decision policy. Until a labeled holdout justifies numeric gates, use verified deterministic decisions and abstain to review. Never treat Gemini's self-reported confidence as a probability. |
| P1 | `leaseNextJob` in `api/src/gemini_queue.js` selects then updates without row locking or a conditional claim (around lines 131–158); two workers can lease one job. `/result` and `/retry` check only `status='leased'`, not lease token/attempt/expiry. | Use atomic `FOR UPDATE SKIP LOCKED` or an equivalent conditional lease, and fence every result/retry by the current lease identity. Test parallel workers and stale responses. |
| P1 | AI job acceptance stores the full SMS body as plain `jsonb` in `ai_jobs.payload` (`gemini_queue.js` around line 58). The payload gate only checks a few keywords and does not catch full identifiers, URLs, references or unusual secret formats. Failure also copies the body into server `needs_review_items.raw_text` (around line 260). The SMS consent screen says text is purged immediately. | Implement automatic redaction/de-identification and the plan's free versus billed Gemini policy, data retention/expiry and truthful consent copy. Do not rely on the bank always masking account data. Decide whether server review storage is allowed; if retained, document/enforce its retention and access policy. |
| P1 | No tested shared-learning loop exists: user review changes are not collected into labeled examples, clustered into candidate templates, evaluated on positive/negative examples, published as versioned rules, downloaded to devices or rolled back. Existing parser pattern CRUD is separate. | Add a privacy-safe feedback-to-candidate pipeline, promotion gates, versioned distribution, local cache/rollback and tests showing a pattern learned from several users benefits a new user without corrupting earlier results. Do not auto-promote one model output. |
| P1 | `console/lib/data/admin_api.dart` adds fetch methods, but no screen or navigation references them. Admin APIs have no batch records, output validation detail, token/rate headroom, wait-time percentiles, correction outcomes or real pagination. | Build the planned read-only SMS AI Operations screen in the existing Flutter Web console, with queue, batches, provider/quota health, outcome counts and a per-job timeline. Expose privacy-safe bounded APIs and exercise them with real RLS access. |
| P1 | `api/src/sms_facts.js` assigns fact slots by sorting current content (around line 287), and its conflict update changes only `updated_at` (around line 421). A parser upgrade or changed fact set can shift slot meanings; old payloads stay forever, and an existing override can attach to a different semantic fact. `completeJobWithResult` also uses `takenIndices.size` as an offset, which can collide with sparse slots. | Give facts stable semantic identities and explicit precedence/version semantics. Preserve user corrections; allow safe parser upgrades; avoid index collision. Add replay tests for changed fields, added/removed facts and sparse slots. |
| P1 | `app/lib/data/user_cards_repository.dart` treats a 400 from `/sms/facts` as success (around line 1428); the outbox then deletes the envelope. A contract mismatch silently loses a recognized balance/bill/mandate fact. | Keep or quarantine rejected envelopes with safe telemetry and a visible repair path. Avoid endless tight retries but do not acknowledge them as delivered. |
| P2 | `api/src/sms_observation_migration.js` defines rollout and backfill helpers, but the live parser/intake does not consult these flags; admin rollout endpoint only displays them. The dry-run API requires the caller to provide observations. | Wire actual per-profile flags into live routes and device behavior, add controlled backfill/dry-run against stored observations, rollback gates and parity metrics. Test old clients and existing checkpoints. |
| P2 | `applyFactSpecialists` in `api/src/sms_facts_route.js` uses `continue` after a duplicate statement date (around line 91), skipping a distinct due-date update on the same fact. | Handle statement and due dates independently and add a regression fixture. |

## Keep these compatibility gates intact

1. On first login and after SMS permission, historical inbox scan and future listener automatically detect SMS. Do not add a user step or wait for Gemini before local detection.
2. Do not reset Android inbox checkpoints or alter existing `smsSourceKey` identity without a migration/alias. Duplicate delivery, restart, background/foreground, backup import and server replay must not create duplicate transactions, jobs or facts.
3. Preserve current `/transactions/from-sms`, batch import, receipts, card matching, due-date healing, bills, bank balance `as of` time, commitments, mandates, subscriptions, and transaction projections. Only posted economic events affect spending.
4. Filter clear OTP/security, promotion and marketing safely. Mixed messages with real financial content must still pass. The three screenshot examples in the master plan should be regression fixtures.
5. Needs Review remains the existing screen. Uncertain items can be corrected or dismissed; corrections sync and have precedence over subsequent rule or AI replays. A user dismissal must not be recreated.
6. Gemini stays server-side, with one project first. GLM is a deferred development adapter. Do not use a second account to bypass quota.
7. User separation, raw-message privacy, access controls, telemetry redaction and retention must be verified with the real database role.

## Implementation sequence for Luna 5.6 High

1. **Baseline and guardrails:** inspect status/diff and master plan; run existing API/mobile/console tests; turn the findings above into failing integration tests. Do not replace the legacy flow wholesale.
2. **Correct the data and security foundation:** RLS worker/admin access, lease fencing, stable fact identities, non-lossy outbox errors, retention, semantic validation and review state contract.
3. **Make facts useful:** common projection path for device, server-rule and AI facts; integrate posted movement, balance snapshot with `as of`, bills, mandates, subscriptions and corrections into existing writers/read models.
4. **Complete the Gemini path:** provider adapter, constrained JSON, sanitizer, durable worker, project quota and backoff, deadline, adaptive microbatch experiment, partial-result handling, events and per-job reconciliation.
5. **Complete learning and UI:** review feedback labels, candidate pattern testing/promotion/version download, admin operations view and privacy-safe metrics.
6. **Roll out safely:** shadow comparison, old-client compatibility, flags actually used in live paths, migration/backfill, canary, rollback, updated phase reports and tests.

Agents may work in parallel on (A) database/queue security, (B) device review and facts, (C) admin UI, and (D) fixture/evaluation design, provided each owns separate files. Luna should own the shared contract and final integration, reconcile all agent changes before testing, and prevent simultaneous edits to `api/src/index.js`, `app/lib/app/providers.dart`, or shared migrations. If agent spawning is unavailable, execute these workstreams sequentially.

## Required verification

- API unit suite and real Postgres integration suite as `app_user` with two users; simultaneous leases, stale result, replay, failed validation, RLS and admin visibility.
- Mobile SMS capture/listener, outbox, dedupe, login scan, review, bills/balances/mandates and offline/restart tests on Android; prove existing checkpoints and receipts survive.
- Console tests plus a manual review of queue, batch, quota, timeline and error states.
- Labeled corpus with positive/negative examples for marketing mixed with financial text, OTP, debit versus declined attempt, bill total/minimum/due, refunds, autopay registration versus debit, balance timestamps and multi-fact SMSs. Record precision/recall and calibration before enabling automatic score-based writes.
- End-to-end Gemini sandbox run with 429, timeout, malformed/partial response, worker crash and quota exhaustion. Assert every job ends in a verified projection or the existing Needs Review screen, with no duplicate spending.

The current `npm test` API suite passed (573 tests, 572 passed, 1 skipped). Flutter test commands did not produce a result in this review session and were interrupted; do not report mobile/console as green based on the phase reports alone.

## Follow-up implementation status (21 October 2026)

The working tree now also includes these verified follow-up changes:

- AI job acceptance consults `sms_facts_pipeline_enabled` and `sms_ai_queue_enabled` before enqueueing. Turning AI off does not disable local SMS intake or the existing deterministic parser.
- Gemini result validation checks printed amount evidence and completed-versus-failed/future movement language. A `upi_bank` balance requires bank/account wording and an SMS-visible four-digit suffix; the account summary query now excludes other balance instruments.
- The worker grows its batch size from one up to its configured maximum after successful batches and halves it after retryable/terminal failures. It sends a batch ID and size with each result; the admin event timeline and summary expose batch counts without message bodies.
- Gemini authentication now uses the `x-goog-api-key` request header so the key does not appear in provider URLs or URL access logs.
- Added focused tests for evidence checks, server rollout gating, batch metadata and adaptive batch sizing.
- Structured user corrections from Needs Review are now written to an on-device SQLite outbox before any server call. They survive offline periods, retry with backoff, contain no SMS text, and are removed only after the server accepts them. The SMS consent page now discloses that an unmatched financial alert may be sent in redacted form to Gemini.

The initial verification above was incomplete and is superseded by the final verification below. The current API suite reports **624 passed, 1 skipped** (the skipped test requires a separate DB test configuration); the full app suite reports **1,150 passed**; the console suite reports **21 passed** and analysis is clean. A local Docker PostgreSQL instance is reachable and the new migrations are present; direct metadata checks confirm forced RLS on user-owned AI/fact tables and an empty AI job queue. A synthetic Gemini batch smoke test passed earlier in this session. The local Docker API image is still from an earlier build, so the current source has not been exercised through a rebuilt API container. No authenticated device session was available, and no live provider-backed queue run was attempted against real SMS data.

### Follow-up implementation status (21 October 2026)

- A database-backed Gemini RPM and estimated-TPM reservation gate now serializes reservations across worker replicas. It stores only timestamps and estimated token counts. Workers wait when capacity is exhausted and renew every leased job before waiting, preventing duplicate work when the wait outlasts the original lease. A provider 429 still enters bounded retry/backoff because an application-side quota gate cannot guarantee the provider will never reject a request.
- The admin SMS AI Operations screen now shows queue states, age, attempts, batches, per-job timelines, compact result/review state, provider request/token use versus configured limits, recent capacity waits, and anonymized per-user quota. It also lists correction candidates and allows reject or “manual pattern authoring” decisions. The UI clearly states this does not activate a parser pattern.
- Confirmed fact corrections now emit privacy-minimized shared-learning signals: a source hash, HMAC sender fingerprint, fact family, and allowlisted changed-field names only. The signal table stores no SMS, correction values, or free-text reason. Candidates require feedback from at least five profiles and require manual authoring; they do not generate executable regexes or train a model automatically. Learning is disabled until `SMS_LEARNING_HMAC_KEY` is set.
- The existing local parser and typed facts continue handling deterministic transaction, bill, balance, card, mandate, and subscription behavior. AI results are evidence-validated; only a bank balance snapshot with bank wording and visible account suffix can clear review automatically. AI bill, mandate, and movement facts remain in the existing Needs Review screen. AI output never invokes the legacy projection specialists; trusted device facts and explicit user corrections still do. Numeric confidence thresholds are intentionally not enabled without a labeled held-out evaluation; Gemini self-reported confidence is not treated as calibrated.
- The automatic login scan, future SMS listener, source-key dedupe, durable local review queue, correction outbox, and existing transaction writers remain in place. Full mobile tests pass. Database metadata and policy checks passed locally, but a repeatable integration test that exercises API operations under `app_user` still needs adding/running before release.

### Final verification update (21 October 2026)

- `npm test`: **624 passed, 0 failed, 1 skipped**. The skipped case is database-dependent.
- `app/flutter test --reporter compact`: **1,150 passed, 0 failed**.
- `console/flutter test --no-pub --reporter compact`: **21 passed, 0 failed**; `flutter analyze --no-pub`: clean.
- `flutter analyze --no-pub lib/app/providers.dart`: clean after the final edit.
- Live local PostgreSQL check: the new tables exist, `ai_jobs` is empty, and `ai_jobs`, `ai_events`, `ai_quota_days`, `sms_sources` facts, overrides, and learning feedback have RLS enabled and forced. `pandapay.ai_claim_next_job` is SECURITY DEFINER. The environment's full test harness still skips its DB test.
- Additional hardening: the AI result path cannot change statement/due day or create/cancel a mandate before user review. Long numeric identifiers separated by spaces or hyphens are redacted before provider submission. Safe balance reconciliation now invalidates the bank summary cache.
- The Dev APK was rebuilt at `app/build/app/outputs/flutter-apk/app-dev-debug.apk` (package `app.pandapay.pandapay.dev2`, version `1.0.5-dev`, code `25`). It was not installed.
- Remaining release gates: rebuild/restart the API container from this source (the running image is two days old); add/run real API tests using DB role `app_user`, including concurrent leasing/RPM reservation and RLS ownership; run a synthetic end-to-end worker flow with a configured worker token/provider key; validate signed-in device behavior and update install while retaining app data. The local worker is opt-in and currently absent. Do not claim production readiness until these gates pass.

### Production-readiness follow-up (21 October 2026)

- SMS AI now fails closed when `sms_ai_queue_enabled` is missing. Pilot activation requires an explicit trusted database flag; the API credentials alone cannot begin queuing messages.
- Cross-user correction signals now honor each profile's existing `contributions_opt_in` setting. The default is off; user-owned correction/fact behavior continues when shared contribution is off.
- The production deployment script and Compose stack now support a separately profiled Gemini worker. Both `AI_WORKER_TOKEN` (32+ characters) and `GEMINI_API_KEY` must be set together in the host-only environment. Disabling the integration stops any existing Gemini worker. The Gemini key is not injected into the API or device.
- The deploy runbook describes 1%→5%→25%→100% staged rollout and immediate feature-flag rollback. It requires first checking queue age, provider waits/retries, result validity, quotas, existing financial projections and Needs Review behavior.
- Gemini 3.8 Flash's current API migration guidance requires removing legacy sampling settings such as `temperature`; the worker now sends only JSON response mode and a regression test rejects reintroducing that parameter.
- A database CI test now exercises RLS isolation between two profiles as `app_user`, worker claim through the constrained SECURITY DEFINER function, and shared RPM reservation/wait behavior. This test has not yet run in this Windows environment because Docker engine access was denied. The API suite passes **627/0/1 skipped**, Compose config validation passes, but these do not replace the DB/worker/device gates.
- Production Supabase remains without the new SMS AI migrations; no live production schema or services were changed. Apply/review migrations via the normal protected release pipeline only after CI passes. The production security advisor also reports `public.schema_migrations` without RLS as a critical exposure; decide and review an appropriate access policy before calling the backend fully production-secure. Do not enable SMS AI until that issue and the migration/CI gates are resolved.

Do not interpret a `done` model job as an automatic financial projection unless its result explicitly clears `reviewRequired`.

## Copy-ready prompt for Luna 5.6 High

> Implement the remaining SMS intelligence work in this repository. Read `docs/SMS_INTELLIGENCE_REVIEW_AND_LUNA_HANDOFF.md` and `docs/SMS_INTELLIGENCE_MASTER_IMPLEMENTATION_PLAN.md` first, then inspect the current working tree. Preserve existing uncommitted changes and the automatic login SMS scan, listener, source-key dedupe, receipts, and all existing product behavior. Address the P0/P1/P2 findings in the handoff in dependency order. You may spawn agents for nonoverlapping database/queue, mobile review/facts, admin UI, and evaluation work; keep the shared contract and final integration under your control. Implement the Gemini worker and adaptive microbatch path, make AI/device facts update existing product projections, reconcile the existing Needs Review screen, complete shared learning and admin monitoring, and make rollout controls real. Add focused real-database and end-to-end tests for the named gates. Run API, mobile and console suites; report exact pass/fail results and any environment limits. Update the phase reports so they reflect verified functionality. Continue until all required gates pass or clearly identify a specific external blocker. Do not declare completion based only on unit tests or phase-report claims.
