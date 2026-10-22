# PandaPay SMS autonomous learning: final completion handoff for Luna 5.6 High

**Prepared:** 22 October 2026  
**Repository:** `C:\Users\sujay\CKProjects\PandaPay`  
**Purpose:** implementation plan and copy-ready orchestration prompt for completing the remaining SMS learning work without changing the consumer app UI or breaking the existing SMS pipeline.

This document is authoritative for the remaining work. Read it together with:

- `docs/SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md`
- `docs/SMS_AUTONOMOUS_LEARNING_AND_CANONICAL_FACTS_PLAN.md`
- `docs/SMS_LEARNING_TECHNIQUE_RESEARCH_AND_DECISION.md`
- `docs/sms-existing-flow-compatibility-audit.md`
- `docs/SMS_INTELLIGENCE_MASTER_IMPLEMENTATION_PLAN.md`

Do not use older phase reports as evidence that the work is complete. Verify the current working tree and actual runtime behavior.

---

## 1. Parent objective

Complete a safe, fully automatic SMS learning loop that improves PandaPay's shared on-device detection over time:

1. Process each SMS once on the device.
2. Drop OTP, PIN, security-secret, clear marketing, and unrelated messages before AI or rule execution.
3. Extract validated canonical facts once and reuse those facts for transactions, balances, bills, due dates, mandates, subscriptions, card identity, and Needs Review.
4. Send plausible but unresolved financial messages through the existing Gemini queue and then Needs Review when uncertainty remains.
5. Convert consent-eligible user confirmations, edits, dismissals, and missed-financial reports into privacy-safe learning evidence.
6. Generate restricted reusable rule candidates automatically.
7. Prove candidates against independent positive and negative evidence.
8. Run real shadow comparison, then deterministic 5%, 20%, and global cohorts.
9. Promote only when measured evidence passes action-specific gates.
10. Pause or roll back automatically when a rule regresses.
11. Download safe versioned rules to devices so future users resolve matching SMS locally.
12. Give administrators visibility and emergency controls without requiring routine manual approval.

The implementation must improve shared detection without allowing one user, one model response, or unlabeled traffic to silently alter behavior for everyone.

---

## 2. Current implementation that must be preserved

The working tree already contains substantial implementation. Luna must inspect and preserve it rather than replacing the pipeline:

- automatic SMS scan after authentication;
- Android future-message listener;
- paged inbox checkpoints;
- stable source-key identity and receipt deduplication;
- local-first capture and offline recovery;
- existing deterministic parser and safety filter;
- queued Gemini fallback and quota handling;
- current Needs Review UI and user flow;
- canonical SMS facts and product projections;
- downloaded global rule bundle and local cache;
- candidate delivery/cache/execution scaffolding;
- dismissal and candidate-exposure outboxes;
- candidate worker, evaluator, migrations, compose configuration, and tests already in the working tree;
- manual user corrections remaining authoritative over parser, AI, and rule replay.

Do not reset SMS checkpoints, rescan all historical messages when rules change, create duplicate transactions, or change the consumer UI.

Unrelated Account/Card/Data-and-storage changes in the working tree belong to another session and must not be reverted or reformatted.

---

## 3. Verified state before this handoff

The most recent review observed:

- API suite: 711 passed, 0 failed, 2 skipped.
- Flutter app suite: 1,212 passed, 0 failed.
- Focused mobile rule/outbox tests: 13 passed, 0 failed.
- `git diff --check`: passed, with Windows line-ending warnings only.
- Real PostgreSQL role/RLS tests: not executed because `SMS_REAL_DB_URL` and `DATABASE_URL` were unavailable.
- Docker migration/compose verification: unavailable because the Docker daemon was not reachable.
- Console suite: attempted but the Flutter process produced no output and had to be stopped.

These passing unit/widget tests do not close the semantic and real-database gaps listed below.

---

## 4. Remaining blocking gaps

### G1 — A dismissal cannot create a reusable ignore rule

`recordReviewDismissal` writes `ignore_noise` as `is_negative = true`, while `proposeCandidates` only clusters `is_negative = false`. Repeated “Not a transaction” decisions therefore prevent unsafe financial candidates but can never synthesize the shared ignore rule required for the next user.

Required correction:

- represent the reviewed decision explicitly, not with one ambiguous boolean;
- a confirmed “not financial” decision is positive evidence for `ignore_noise` and hard-negative evidence for financial families that predicted the source;
- one decision may create multiple normalized labels, but all writes must be idempotent;
- one user must never be sufficient for shared activation;
- `ignore_noise` keeps the strictest promotion gate and cannot override credible financial evidence.

### G2 — Shadow evidence does not measure candidate correctness

The device evaluates shadow candidates but records the existing pipeline's final outcome. Corrections and false-discard flags are currently attached only to applied candidates. A bad shadow rule can therefore accumulate exposure with zero measured errors and progress after time/sample thresholds.

Required correction:

- execute the current baseline and shadow candidate independently on the same SMS;
- never apply shadow facts to the user's data;
- persist a privacy-safe comparison result containing candidate/baseline family, disposition, fact validity, exact-field equality, and protected invariant results;
- record categorized deltas such as `agreement`, `candidate_miss`, `candidate_extra_financial`, `wrong_family`, `wrong_amount`, `wrong_date`, `invalid_fact`, `duplicate_risk`, and `projection_mismatch`;
- promotion must require enough comparable or independently labeled outcomes;
- absence of corrections or labels must not count as success.

### G3 — Cohort telemetry is not consent-safe

`POST /sms/rule-exposures` currently accepts events from every authenticated profile, and those events drive shared promotion/rollback. Opt-out deletes only some learning examples.

Required correction:

- enforce `contributions_opt_in = true` server-side for all evidence used by shared learning;
- device-side suppression may reduce traffic, but the server check is mandatory;
- revoking consent must remove or permanently exclude the profile's unpromoted learning examples, correction aggregates, candidate exposures, shadow comparisons, and assignment evidence;
- profile deletion must cascade through all user-linked learning rows;
- already published immutable global bundles may remain, but future evaluation must not retain or recompute from revoked evidence;
- add real RLS tests proving one profile cannot read or mutate another profile's evidence.

### G4 — Active regression rollback is unreachable

The active-candidate branch checks `candidate.bundle_version`, but the worker query does not select `bundle_version`.

Required correction:

- select and validate `bundle_version` for active candidates;
- test that a regressed active rule calls rollback, changes candidate state, deactivates the bundle, and disappears from subsequent device responses;
- make rollback atomic and idempotent;
- record the rollback reason and worker run that caused it.

### G5 — Offline corrections lose the structural learning example

The durable correction outbox stores patch/reason but drops template/sample information. Immediate online corrections may create learning evidence, while the same user action performed offline later syncs without enough information to create a candidate example.

Required correction:

- extend the SQLite correction outbox additively;
- store a locally redacted structural template, expected typed fields, label source, parser/rule/model versions, and required provenance;
- do not require raw SMS replay to learn from a review;
- migrate existing rows safely and allow old rows to sync as corrections even if they cannot contribute a learning example;
- preserve account namespace isolation and retry backoff.

### G6 — Delayed exposure events are dropped after a stage transition

The exposure insert currently requires the reported stage to equal the candidate's current state. Offline devices reporting a legitimate earlier assignment after promotion/pause lose their evidence.

Required correction:

- create a persisted candidate assignment/stage-epoch identity;
- return an opaque assignment ID or stage version in the bundle response;
- key idempotency by candidate, profile, source key, and assignment/stage epoch;
- accept delayed events only when they match a real assignment previously issued to that profile;
- do not accept arbitrary client-supplied historical stages;
- merge later terminal outcomes monotonically instead of using unconditional `DO NOTHING`;
- keep the raw SMS body out of telemetry.

### G7 — Minimum client version is not enforced

The bundle carries `minClientVersion`, but the device does not compare it with the installed version.

Required correction:

- use the app's existing version source/version comparison helper;
- refuse incompatible global and candidate bundles;
- retain the last compatible safe bundle offline;
- report only an operational compatibility status, without SMS content;
- test older client, malformed version, current client, rollback to compatible bundle, and old API responses.

### G8 — Admin monitoring still represents the old manual workflow

The console currently shows aggregate correction candidates and manual pattern-authoring/reject buttons. It does not expose the autonomous state machine or operational health.

Required correction:

- add read APIs and console presentation for candidate state, family, issuer, evidence counts, independent users, assignment/cohort size, comparison outcomes, correction/false-discard/missed-financial rates, observation window, worker last run/failure, active bundle, previous bundle, and rollback reason;
- add emergency pause/resume and bundle rollback actions with admin audit records;
- remove routine manual approval as a promotion dependency;
- retain existing admin visual patterns and navigation;
- do not expose raw SMS or redacted message samples in ordinary admin screens.

### G9 — Worker identity is hard-coded to superuser-style names

The worker currently accepts only roles literally named `postgres` or `service_role`, despite the requirement for a dedicated least-privilege identity.

Required correction:

- provision or document a dedicated `sms_learning_worker` role;
- grant only the tables/functions required for clustering, evaluation, telemetry aggregation, candidate transitions, publication, rollback, and worker health;
- reject `app_user` and any role missing required capabilities;
- validate privileges/capabilities rather than permitting only two hard-coded role names;
- do not place database URLs or secrets in code, docs, logs, or test snapshots.

### G10 — Release gates are not yet proven against PostgreSQL and Docker

Required correction:

- apply migrations to both a clean database and an upgraded database;
- run tests as user A, user B, admin, `app_user`, and the dedicated worker role;
- run two workers concurrently and prove one publication;
- verify compose configuration and worker startup/shutdown;
- verify the full synthetic learning path with persisted rows;
- do not declare completion while real database tests are skipped.

---

## 5. Target evidence and cohort contract

Luna owns this shared contract. Freeze it before agents edit dependent files.

### 5.1 Learning example

Each consent-eligible structural example needs:

- `profile_id` for deletion lineage;
- HMAC `user_hash` and sender fingerprint;
- target family and expected disposition;
- redacted template or restricted token/slot representation;
- expected canonical fields and typed values needed for exact extraction tests;
- label source: `user_confirmed`, `user_edited`, `dismissed_not_financial`, `missed_financial`, `independent_reconciliation`, or `weak_ai_proposal`;
- positive/negative relationship to each evaluated family;
- parser version, rule ID/version, bundle version, and AI model/version when relevant;
- creation time and source-key hash for idempotency;
- consent/deletion lineage.

Weak AI or parser labels may suggest candidates but must never certify themselves.

### 5.2 Candidate assignment

Persist a server-issued assignment record containing:

- assignment ID;
- candidate ID and immutable candidate revision;
- profile ID;
- stage and stage epoch/version;
- mode: shadow or apply;
- deterministic cohort bucket;
- issued and expiry/revocation timestamps;
- minimum client version;
- candidate rule checksum.

The assignment must be stable across retries and independent of SMS content.

### 5.3 Exposure/comparison event

One idempotent row per assignment and source key:

- assigned/matched/applied;
- baseline and candidate family/disposition;
- baseline/candidate fact validity;
- exact-field comparison flags without raw values where possible;
- categorized delta/outcome;
- confirmed/edited/dismissed/missed-financial terminal label when available;
- protected invariant flags: duplicate economic event, credible-financial discard, invalid amount/date, or projection mismatch;
- first-seen and last-updated timestamps;
- consent/deletion lineage.

Use monotonic updates: a terminal user label may enrich an earlier exposure, but a retry cannot erase it or inflate counters.

### 5.4 Canonical facts remain the single source for product features

Rules and Gemini produce candidate facts; validated accepted facts remain the shared source for:

- posted movement and spending totals;
- balance snapshot with as-of time;
- bill obligation, total/minimum due, statement date, and due date;
- bill payment;
- mandate/autopay lifecycle;
- subscription/recurring series;
- card/account identity hints;
- pending/failed/reversed attempts;
- Needs Review.

Do not add separate feature-specific SMS regex passes. Preserve legacy adapters until fact projection parity is demonstrated family by family.

---

## 6. Automatic state machine and gates

### Proposed

- Require the configured minimum independent users.
- Generate only the restricted rule DSL/regex subset.
- Reject wildcard senders, unsafe regex, unsupported fields, secrets, and ambiguous templates.
- Deduplicate candidate revision deterministically.

### Evaluated

- Require post-creation examples from users who did not contribute to candidate generation.
- Include standard and observed hard negatives.
- Validate exact amount/date/entity extraction and cross-family behavior.
- Keep insufficient evidence pending; do not reject or promote merely because the first cycle lacks holdout.

### Shadow

- Deliver to eligible consenting devices for evaluation only.
- Apply 0% of candidate facts.
- Compare candidate output against baseline and later user labels.
- Require a minimum observation window, independent users, comparable examples, and family-specific statistical bound.
- Do not pass based on zero reported corrections.

### Limited

- Stable 5% cohort.
- Candidate may act only after local safety, required-field, confidence, and invariant checks.
- Track correction, false financial result, missed financial result, invalid fact, duplicate, review, and downstream projection rates.

### Expanded

- Stable 20% cohort.
- Require a new observation window and enough independent evidence from this stage.
- Do not carry previous-stage counts forward as new-stage evidence.

### Active

- Publish an immutable checksummed bundle for 100% compatible clients.
- Continue monitoring active-rule evidence.
- On proven regression, atomically deactivate the affected bundle/rule, mark candidates rolled back, and serve the previous safe bundle or built-in fallback.

### Pause versus rollback

- Pause when evidence is insufficient, conflicting, unavailable, or the provider/worker is unhealthy.
- Roll back when a protected invariant is breached or measured regression exceeds its family-specific bound.
- Never lower thresholds through an admin request or model output.

---

## 7. Parallel implementation structure

Luna is the parent/integration owner and may spawn exactly three implementation agents. All agents share the same checkout. They must not create worktrees, revert other changes, run broad formatters, or edit outside their ownership without first messaging Luna.

### Parent — Luna 5.6 High

Responsibilities:

- read all authoritative documents and the complete current diff;
- create a concise file ownership ledger before spawning;
- freeze the evidence/assignment/exposure JSON and SQL contract;
- own changes that cross agent boundaries;
- resolve merge conflicts and reconcile naming/versioning;
- inspect every agent diff rather than accepting completion claims;
- run final integration and release gates;
- update documentation with verified results only;
- leave unrelated user changes untouched.

### Agent A — database, consent, assignment, and cohort API

Owned files:

- additive `db/supabase/migrations/*sms_learning*` and `*sms_rule_cohort*` migrations;
- `api/src/sms_facts_route.js`;
- `api/src/sms_rule_bundle.js`;
- new cohort/assignment/telemetry API modules;
- focused API and real-DB tests for those modules.

Tasks:

1. Implement the frozen evidence, assignment, stage epoch, exposure, worker-run, and audit schema additively.
2. Enforce opt-in and deletion lineage for every shared-learning input.
3. Replace current-state equality with verifiable persisted assignments for delayed events.
4. Make event ingestion idempotent and terminal-outcome updates monotonic.
5. Return global and candidate bundles only for valid stable assignments and compatible clients.
6. Ensure paused/rejected/rolled-back candidates are never served.
7. Add aggregated admin read endpoints without raw SMS.
8. Add emergency pause/resume/rollback endpoints with audit records.
9. Prove RLS and grants with real PostgreSQL roles.

Agent A must not change device parsing or worker thresholds.

### Agent B — device comparison, outboxes, compatibility, and replay

Owned files:

- `app/lib/data/local/sms_rule_bundle*.dart`;
- `app/lib/data/local/sms_import_store.dart`;
- `app/lib/data/local/sms_rule_exposure_outbox.dart`;
- `app/lib/data/local/sms_dismissal_outbox.dart`;
- `app/lib/data/local/sms_facts_outbox.dart`;
- `app/lib/data/user_cards_repository.dart`;
- `app/lib/features/sms_import/sms_capture_worker.dart`;
- the minimum required wiring in `app/lib/app/providers.dart`;
- focused mobile tests.

Tasks:

1. Validate global/candidate envelope, checksum, restricted fields, assignment identity, stage, mode, and minimum client version.
2. Preserve last compatible safe bundle and built-in fallback.
3. Execute baseline and shadow candidate independently, applying neither shadow facts nor shadow ignores.
4. Produce privacy-safe comparison outcomes using the frozen contract.
5. Ensure limited/expanded/active candidates remain behind local safety and canonical fact validation.
6. Extend correction/dismissal/exposure outboxes for durable consent-safe evidence without requiring raw SMS replay.
7. Keep outboxes account scoped and safe across restart, auth restoration, network restoration, and account switch.
8. Ensure repeated inbox/listener delivery creates one receipt, one exposure, and at most one economic event.
9. Keep user overrides authoritative.
10. Do not change the Needs Review layout or consumer navigation.

Agent B must not change SQL policies or worker promotion thresholds.

### Agent C — worker, evaluator, admin monitoring, and operations

Owned files:

- `api/src/sms_autonomous_worker.js`;
- `api/src/sms_evaluator.js`;
- `api/src/sms_learning.js`;
- `api/src/sms_learning_worker_runner.js`;
- worker/evaluator tests;
- `console/lib/data/admin_api.dart`;
- `console/lib/app/providers.dart`;
- `console/lib/features/dashboard/sms_ai_operations_screen.dart` and focused console tests;
- `.env.*.example`, `docker-compose.*.yml`, and `deploy/deploy.sh` after Luna approves the contract.

Tasks:

1. Correct dismissal/ignore and missed-financial label semantics.
2. Generate candidates only from eligible structural evidence.
3. Enforce independent post-creation holdout and exact extraction checks.
4. Consume persisted comparison/exposure metrics and implement the stage gates above.
5. Fix active `bundle_version` selection and prove rollback.
6. Use one pinned PostgreSQL session and one correctly balanced advisory lock per cycle.
7. Implement least-privilege worker capability checks and clean shutdown.
8. Persist worker run health and failure codes without sensitive payloads.
9. Replace the old admin candidate section with autonomous monitoring and emergency actions while retaining the existing visual design.
10. Validate compose/deploy startup combinations for Gemini enabled/disabled and learning enabled/disabled.

Agent C must not weaken thresholds or treat mocked exposures as evidence.

---

## 8. Dependency order and synchronization points

1. **Luna:** snapshot `git status`, read the full diff, and record unrelated changes.
2. **Luna + Agent A:** freeze database and JSON contracts first.
3. **Agent A:** implement additive migration and API contract.
4. **Agent B:** implement against the frozen response/event contract.
5. **Agent C:** implement worker consumption and admin APIs/UI against persisted Agent A data.
6. **Luna:** reconcile the shared `sms_facts_route`, provider wiring, API registration, package scripts, and documentation.
7. **All agents:** report owned files, exact tests, failures, and unresolved risks.
8. **Luna:** inspect diffs, run integration tests, fix cross-component failures, and repeat the real end-to-end loop.

Agents may work in parallel after the contract is frozen. Schema naming, stage semantics, outcome values, and version fields must not diverge.

---

## 9. Required tests

### API unit/integration tests

Add tests proving:

- dismissal supplies positive `ignore_noise` evidence and financial hard-negative evidence;
- one user cannot promote a shared rule;
- non-consenting profiles create no shared evidence;
- opt-out deletes/excludes every linked unpromoted evidence type;
- duplicate exposure retry does not increment counts;
- a later terminal outcome enriches but does not duplicate an exposure;
- delayed valid assignment events are accepted after stage transition;
- fabricated assignments/stages are rejected;
- shadow cannot pass from exposure count alone;
- exact-field mismatch blocks promotion;
- protected invariant breach pauses or rolls back;
- zero exposure cannot promote;
- active candidate regression rolls back its bundle;
- paused/rolled-back candidate disappears from delivery;
- two concurrent workers do not publish twice;
- admin input cannot override production gates;
- old API/device response behavior remains compatible.

### Mobile tests

Add tests proving:

- OTP/PIN/security/clear promotion filters run before every downloaded rule;
- shadow output never changes facts, transactions, review items, or intake decisions;
- shadow comparison differentiates agreement and each material mismatch;
- cohort assignment is cached and stable;
- incompatible client version rejects the new bundle and retains the last safe bundle;
- broken checksum/regex/field map rejects the entire candidate safely;
- correction evidence survives offline restart;
- dismissal and exposure events survive offline restart;
- account switch never sends the former account's events;
- duplicate inbox scan/listener delivery records one exposure and one economic event;
- bundle rollback clears revoked candidates without resetting the SMS checkpoint;
- user override wins after rule refresh/replay;
- transactions, balance-as-of, bills/due dates, mandates, subscriptions, and Needs Review still read the canonical source correctly.

### Cross-runtime fixtures

Create one fixture corpus consumed by JS and Dart that covers:

- valid movement, bill, balance, mandate, and ignore templates;
- Indian amount formats and paise precision;
- due/statement date formats;
- OTP/security collisions;
- promotion plus amount;
- actual transaction plus cashback footer;
- EMI offers;
- refund, reversal, failed, pending, and declined cases;
- sender mismatch;
- unsafe regex and capture bounds;
- exact expected extracted fields.

JS and Dart must agree on match/no-match and normalized fields.

### Real PostgreSQL tests

Use a disposable local database and run migrations from scratch and over the previous schema. Prove:

- user A cannot read/update user B evidence or assignments;
- `app_user` cannot read the cross-user corpus or operate the worker;
- admin can read only approved aggregate operations data;
- dedicated worker can perform required operations and nothing broader;
- opt-out and profile deletion remove all linked evidence;
- RLS remains forced;
- SECURITY DEFINER functions verify caller authority internally;
- advisory lock prevents duplicate concurrent cycles;
- publication and rollback are atomic;
- late assignment telemetry and idempotent replay work under transactions.

### Full suites and operational checks

Run from the repository root or specified subdirectory:

```text
cd api
npm test

cd app
flutter analyze --no-pub
flutter test --no-pub

cd console
flutter analyze --no-pub
flutter test --no-pub

git diff --check
```

Also run:

- clean and upgrade migration tests with `SMS_REAL_DB_URL`;
- `docker compose ... config` for production and staging profiles;
- learning-only, Gemini-only, both-enabled, and both-disabled service startup;
- graceful worker shutdown;
- deploy script syntax check in a Bash environment.

Record exact pass/fail/skip counts and the environment used.

---

## 10. Synthetic end-to-end acceptance scenario

The final implementation is incomplete until this scenario passes with persisted database rows:

1. User A installs/signs in and the existing inbox scan runs automatically.
2. A new plausible financial SMS is not understood locally.
3. It follows the existing Gemini/Needs Review path.
4. User A confirms/edits it while contribution is enabled.
5. The correction survives an offline restart and syncs once.
6. Users B–E contribute independent examples; no one user's data is enough.
7. The worker proposes a restricted candidate.
8. Later independent users provide a post-creation holdout.
9. The candidate passes exact positive, hard-negative, historic, and JS/Dart parity checks.
10. Shadow execution records real comparison deltas without changing user data.
11. Insufficient/unlabeled shadow traffic keeps the candidate pending.
12. Labeled healthy evidence moves it through stable 5% and 20% cohorts.
13. A compatible new user's device downloads the active version and resolves the SMS locally.
14. Different amount, account last four digits, due date, and merchant values extract correctly.
15. The canonical facts update each relevant view once.
16. Duplicate delivery creates no duplicate exposure or transaction.
17. A user correction becomes an error signal for the applied candidate.
18. A candidate-induced false financial result becomes a false-discard signal.
19. A wrongly ignored financial message becomes a missed-financial signal.
20. Injected regression automatically pauses or rolls back the rule and devices receive the previous safe bundle.
21. A non-consenting user contributes no shared evidence.
22. Revoking consent removes that user's unpromoted evidence.
23. Admin sees worker/candidate/bundle health and rollback reason without seeing SMS text.

Repeat the same pattern for movement, balance, bill/due date, mandate, subscription/recurring, and ignore filtering where the family contract permits it.

---

## 11. Compatibility gates that must remain green

- First login still starts automatic SMS detection after permission/auth restoration.
- The existing app update path preserves session and local database.
- Already processed SMS messages are not reprocessed.
- Inbox checkpoint only moves forward after durable local capture.
- Listener and historical scan converge on the same source key.
- Offline capture continues without API availability.
- Raw OTP/PIN/security SMS never enters learning, Gemini, or ordinary logs.
- Clear promotional/unrelated decisions are stored once and do not repeatedly reappear.
- A credible transaction with promotional footer is not discarded.
- Gemini failures/429/quota exhaustion leave durable retry or Needs Review, not data loss.
- Manual user facts/card settings remain authoritative.
- Balance shows its source timestamp/as-of date.
- Bills keep total due, minimum due, statement date, and due date distinct.
- Posted movement alone changes spending totals.
- Account namespaces never cross during logout/login or account switch.
- No consumer app UI/layout change is introduced.

---

## 12. Completion definition

Luna may declare the work complete only when all of the following are true:

- G1–G10 are implemented or explicitly demonstrated as already correct.
- Every agent's diff has been reviewed and integrated.
- No unrelated user changes were reverted.
- API, app, and console full suites pass.
- Static analysis passes for app and console.
- Clean/upgrade PostgreSQL migrations and real RLS role tests pass without skips.
- Cross-runtime rule fixtures pass.
- Concurrent worker and automatic rollback tests pass.
- Docker/compose/deploy checks pass.
- The synthetic end-to-end scenario passes with persisted evidence.
- Admin monitoring shows the autonomous state machine and worker health.
- Existing SMS compatibility gates remain green.
- Documentation reports actual commands/results and any genuinely external blocker.

Passing mocks or unit tests alone is not completion.

---

## 13. Copy-ready prompt for Luna 5.6 High

Paste everything below into Luna 5.6 High:

> Work as the senior integration owner for the remaining PandaPay SMS autonomous-learning implementation in `C:\Users\sujay\CKProjects\PandaPay`.
>
> First read `docs/SMS_AUTONOMOUS_LEARNING_FINAL_COMPLETION_HANDOFF_FOR_LUNA.md` completely, followed by every authoritative document linked at its top. Inspect `git status`, the entire uncommitted diff, current migrations, API/mobile/console code, and existing tests before editing. Preserve all current work and all unrelated changes. Do not reset, revert, clean, or broadly format the checkout.
>
> Create a parent implementation checklist from sections 4–12 of the handoff. You are the parent and final integration owner. Spawn exactly three agents after freezing the evidence, assignment, exposure, and bundle contract:
>
> 1. **Database/cohort agent:** own additive SMS learning/cohort migrations, `api/src/sms_facts_route.js`, `api/src/sms_rule_bundle.js`, cohort/assignment/telemetry APIs, and real-database tests.
> 2. **Device agent:** own mobile bundle validation/cache, shadow comparison, SMS import integration, correction/dismissal/exposure outboxes, repository/provider wiring, and focused mobile tests.
> 3. **Worker/admin/operations agent:** own autonomous worker/evaluator/learning modules, worker runner, admin monitoring API/console, compose/deploy/env examples, and related tests.
>
> Give each agent the exact ownership, tasks, constraints, and acceptance tests from section 7. All agents share one checkout: they must not create worktrees, revert another agent's files, edit outside ownership without coordinating, or declare completion from mocks. Require each agent to report changed files, exact tests, failures, and risks. Keep cross-agent contracts and final integration under your control.
>
> Implement every blocking gap G1–G10. In particular:
>
> - make confirmed “not financial” decisions positive evidence for strict `ignore_noise` learning and hard-negative evidence for incorrect financial hypotheses;
> - implement real privacy-safe shadow comparison against the current pipeline; exposure count with no labels must never be treated as success;
> - enforce contribution consent and complete opt-out/deletion across examples, feedback, assignments, exposures, and comparisons;
> - fix active candidate `bundle_version` retrieval and prove automatic rollback;
> - preserve structural learning evidence through offline correction replay without requiring raw SMS replay;
> - persist verifiable assignment/stage epochs so delayed legitimate telemetry is accepted and fabricated telemetry is rejected;
> - enforce minimum client version and retain the last compatible safe bundle;
> - replace the old manual admin candidate view with autonomous candidate/cohort/worker/bundle monitoring and audited emergency pause/resume/rollback controls;
> - use a dedicated least-privilege learning worker identity validated by capabilities, not a hard-coded superuser role name;
> - apply and test migrations on clean and upgraded real PostgreSQL databases.
>
> Preserve the current automatic post-login SMS scan, future listener, checkpoints, source-key receipts, deduplication, local-first/offline behavior, Gemini queue, canonical facts, current transaction/balance/bill/mandate/subscription behavior, user override priority, and current Needs Review UI. Do not add a consumer UI or rescan historical SMS when rules update.
>
> Build the evidence/state-machine contract from sections 5 and 6. Use restricted checksummed rules only. Keep OTP/PIN/security and clear promotional filtering ahead of all downloaded rules. Never allow Gemini, an admin request, one user, unlabeled traffic, or a candidate's own training examples to certify that candidate. Pause on uncertainty and roll back on measured regression.
>
> After agents finish, inspect and reconcile every change personally. Run all tests in section 9, including full API/app/console suites, static analysis, cross-runtime fixtures, real PostgreSQL RLS/role/migration tests, concurrent-worker locking, Docker compose/deploy checks, and the complete persisted synthetic scenario in section 10. Fix failures rather than documenting around them. Report exact pass/fail/skip counts and commands. Do not claim completion while real database gates are skipped or Docker/console checks remain unavailable.
>
> Update the handoff or a final verification report with verified behavior only. Finish only when every item in section 12 is satisfied. Do not commit, push, deploy, or expose secrets unless the user separately asks for those actions after reviewing the completed diff.

