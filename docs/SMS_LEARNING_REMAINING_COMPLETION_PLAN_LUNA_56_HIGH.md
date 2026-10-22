# SMS intelligence: remaining completion plan for Luna 5.6 High

**Status:** implementation handoff and acceptance contract, 22 October 2026. This document distinguishes code that exists from behavior that is proven. It does not supersede the product decisions in [SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md](SMS_INTELLIGENCE_FINAL_AUTONOMOUS_IMPLEMENTATION_PLAN.md).

## Model and execution

Use **Luna 5.6 High**. The remaining work crosses Dart parsing, API authorization, PostgreSQL privileges, asynchronous replay, and deployment. A lighter setting may handle isolated tests, but the parent integrator should stay on High. Spawn three agents with disjoint files: device candidate matching, dismissal feedback, and dedicated worker role/deployment. The parent owns this plan, canonical fact integration, reconciliation, and final gates. Agents must not commit or deploy independently.

## Goal and non-regression contract

A fresh or returning user should scan SMS once, filter definite OTP/promotional/unrelated messages on-device, create one durable source decision, save the applicable typed facts, and use the existing Needs Review screen for uncertainty. A consented correction or dismissal may teach a restricted candidate rule. The candidate must survive independent positive and hard-negative evaluation, shadow and limited cohorts, and regression monitoring before it reaches the shared active bundle. A later user should resolve the same wording with changed values locally. Bad rules must pause or roll back automatically.

Preserve the existing post-login scan, future-message listener, checkpoint/source-key deduplication, offline queues, receipts, user overrides, transaction totals, card/balance, bill, mandate, subscription, and Needs Review behavior. Keep the consumer UI unchanged. Avoid replaying old SMS merely because a rule bundle changes. Never let a learned rule override OTP/PIN/CVV protection or a confirmed user decision.

## Current evidence and gaps

The code already contains local triage, canonical observations/facts, a Gemini queue, rule bundles, candidate synthesis/evaluation, cohort exposure telemetry, rollback mechanisms, and admin monitoring. [SMS_AUTONOMOUS_LEARNING_IMPLEMENTATION_VERIFICATION.md](SMS_AUTONOMOUS_LEARNING_IMPLEMENTATION_VERIFICATION.md) records passing local suites but leaves real database, worker, multi-user, and physical update-build gates open. Recheck that report after changes; do not treat its implementation bullets as runtime proof.

1. **Candidate family mismatch.** `app/lib/data/local/sms_import_store.dart` counts `downloaded_rule_match` and `downloaded_rule_noise_match`, while `app/lib/data/local_sms_parser.dart` emits `downloaded_rule_balance`, `downloaded_rule_bill`, and `downloaded_rule_mandate`. This turns valid learned candidates into misses and blocks their limited-cohort application.
2. **Unresolved dismissal feedback.** `POST /sms/dismiss` in `api/src/sms_facts_route.js` rejects an unknown source key with 404. A user can dismiss an SMS before that source is on the server; the local dismissal outbox then retries without resolution. Commitment review items use a prefixed `commitment:<hash>` ID, which also fails the API's hex-only source-key validation with 400. Normalize that local review ID to its canonical hash for transport while retaining the existing UI identity. Keep server-derived hard-negative family labels only for owned canonical facts or verified exposures. A source-less/unknown-source dismissal may contribute only a redacted, consent-gated positive ignore label tied to that authenticated user; it must not fabricate another user's source or override a confirmed financial event.
3. **Dedicated worker bootstrap and admin cycle.** The worker requires a separate `sms_learning_worker` role, while the health migration grants privileges only if that role already exists. Provision the login role through the established deployment/database setup, grant the minimum required privileges after migrations, and verify RLS as that role. The admin cycle endpoint currently runs through `withUserClient` (`app_user`), which the worker capability gate rejects. Route an admin-triggered cycle to a safe worker trigger or explicitly remove/disable the unusable operation; never give `app_user` worker powers.
4. **Canonical projection coverage.** Local capture saves observations, but only some dispositions enqueue typed facts directly. Map each family to the existing transaction, balance, bill, mandate, and subscription projection path. Preserve existing server contracts during staged cutover. Add lineage/override tests before declaring that every feature is driven by one fact source. Do not replace a working transaction path just for architectural uniformity.
5. **Runtime proof.** Apply all new migrations in a clean database and an upgraded database, run real `app_user`, admin, and worker-role tests, start the worker through Compose, and exercise a persisted multi-user candidate lifecycle. Test an update build with the same dev application ID and intended backend URL; preserve the signed-in session.

## Work packages and ownership

### A. Device candidate parity (agent A)

Own `app/lib/data/local/sms_import_store.dart` and focused Dart tests. Replace reason-code special cases with a single typed downloaded-rule match signal, or an exhaustive family mapping that cannot silently exclude a supported family. Verify the matched candidate remains subject to safety triage and fact validation. Test transaction, noise, balance, bill with due date, mandate setup/cancellation, candidate miss, shadow (telemetry only), and limited apply. Assert extracted values and resulting facts, not just reason codes. Leave scanner checkpoints and UI untouched.

### B. Dismissal feedback and replay (agent B)

Own `api/src/sms_facts_route.js` and focused API tests. Inspect `app/lib/data/user_cards_repository.dart`, `app/lib/data/local/sms_dismissal_outbox.dart`, and Needs Review IDs to distinguish canonical source keys from local review identifiers. For an owned source, record the existing verified feedback and exposure outcome. For an unknown source, use authenticated sender plus redacted sample only when consent is active; record an `ignore_noise` positive with low provenance, without a hard negative or source ownership claim. Reject an explicitly foreign owned source. Make the retry response terminal only when feedback is durably recorded or intentionally disabled by consent. Add offline-first and duplicate-delivery tests. Coordinate the admin-cycle endpoint edit with agent C.

### C. Worker privileges and operations (agent C)

Own database setup/migration/deployment files, worker bootstrap, and focused tests. Create/provision a distinct `sms_learning_worker` login without a checked-in password. Confirm migration order and grants on every table/function the worker queries or writes, including bundle publication and health records. Verify `app_user` cannot assume the role or publish bundles. The worker must fail visibly when credentials/privileges are missing, retain lease and idempotency behavior on restart, and expose run health. Replace or disable the admin cycle path that incorrectly uses `app_user`; admin should use pause/resume/status without becoming a publisher. Test role creation on both fresh and existing databases, including the case where a migration ran before role creation.

### D. Parent integration: one source of truth

Create a family-by-family matrix showing where an SMS is parsed, persisted, synced, and projected today. Cover posted debit/credit, available balance, card bill total/minimum/due date, payment toward bill, mandate lifecycle and actual debit, pending/failed/reversed/refunded attempts, and recurring subscription series. Identify duplicate regex extraction and any canonical fact absent from the server or local store. For each family, add shadow comparison first, then route the product view to authoritative facts only after parity and user-override tests pass. Keep old-client/API compatibility and exact source-key idempotency. Do not assume that a local observation row alone satisfies the server-wide fact contract.

## Required scenario tests

1. Fresh install, mixed inbox, offline then online: one scan, no repeated historical processing, correct local facts before Gemini, and eventual outbox receipt.
2. SMS during scan plus broadcast/listener and duplicate API delivery: one source decision and at most one economic event.
3. OTP/PIN/CVV, pure offer with amount, service alert, genuine debit with cashback footer, and bill notice with offer text: correct hard safety and relevance gates.
4. Unknown financial wording with Gemini success, quota exhaustion, timeout, and malformed output: safe fallback into existing Needs Review; no duplicate posting.
5. User confirm/edit/dismiss before server source exists; offline retry; consent off; account switch; correction after late AI response: terminal, isolated outcome with user decision winning.
6. Balance, bill, and mandate learned candidates: shadow exposure, limited application, exact amount/date/entity capture, later-user value variation, and negative near-match rejection.
7. Promotion candidate: hard-negative financial examples prevent false ignore. A single user's label cannot publish a shared rule.
8. Candidate regression, invalid bundle/checksum, obsolete client, rollback while device offline, worker crash/concurrent cycles: deterministic fallback and no checkpoint reset.
9. Transaction, balance, bill, mandate, and subscription product projections: same accepted facts, correct as-of dates, no bill amount counted as spending, no fabricated subscription or duplicate debit.
10. Admin operations: visible queue/worker/candidate state, safe pause/resume, no failed trigger disguised as success; no consumer UI changes.

## Verification and release gates

Run focused tests after each package, then API, Flutter app, and console full suites and static analysis. Run `git diff --check`. Use real PostgreSQL for migration and role tests under `app_user`, admin, and `sms_learning_worker`; mocks are insufficient for RLS. Use Docker Compose to prove the worker starts, executes a cycle, records health, publishes, and rolls back. Seed a redacted corpus with multiple independent users and both positive and negative examples, then demonstrate a new user downloading and applying an approved bundle. Finally install an **update** APK over the existing PandaPay Dev app, with unchanged application ID/signing and the correct backend URL, and verify retained login and first/future SMS behavior. Record exact commands, results, environment, and any unavailable gate in an updated verification report. Do not claim production ready while any required gate is unrun.

## Completion definition

Complete only when all four gap groups above are fixed, all scenario gates pass, and a previously unknown reviewed template progresses without admin rule approval to a validated shared bundle that another device uses locally. The same source must not create duplicate financial events; uncertainty must remain reviewable; regressions must stop and roll back automatically. Commit or deploy only after the integrated diff and runtime evidence are reviewed.
