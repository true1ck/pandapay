# SMS pipeline v2 continuation — 3 November 2026

Documentation review checkpoint. Implementation is paused at the owner's request while the existing plan and handoffs are reconciled. This note records the design rationale, verified state and execution sequence; it does not replace or amend the frozen contracts or the exported plan.

## Sources and authority

Read together:

- `../README.md`, `../overview.md`, `../playbook.md`, `../contracts.md`, `../test-and-release.md`.
- The work-package index and all individual specifications, WP-00 through WP-17.
- All existing handoffs: WP-00, WP-01, WP-02, WP-03a–03d, WP-04, WP-05, WP-07, WP-08 and WP-09.
- All six existing requests under `../requests/`.

The exported v2 plan is the implementation source. Older SMS plans describe the system being replaced and supply format inventories; they do not override this plan. The work-package index records integration status. Handoffs explain implementation decisions and limitations, but do not silently change a contract.

## Design rationale to preserve

Capture, safety checks, stable source keys and durable intake remain. The middle of the pipeline changes because isolated message parsing cannot identify a bank debit and a card receipt as one payment.

The flow is:

1. Capture and safety gate on the phone.
2. One pure-Dart rule engine extracts typed facts from a versioned bundle.
3. The instrument registry resolves the user's account, card, wallet or broker.
4. The linker joins facts into stable real-world events.
5. One category resolver categorises spending with user choices first.
6. One ledger projector owns money movement, totals and counts.
7. Existing screens and rewards keep their existing input types through adapters.
8. The phone uploads compact facts and changes in batches; the server validates, stores and syncs them without parsing SMS text.

A fact says what a message states; it does not decide whether something is spending. A hold is not a debit. A card-bill payment and an own transfer are not spending. A second notice is not another payment. Money uses integer paise and points use whole points. Uncertainty goes to review.

Amazon Pay is the explicit exception to ordinary wallet accounting: its top-up counts as an Amazon purchase in `online`; its balance-payment notices do not count again. For wallets with complete purchase SMS visibility, the top-up is a transfer and each wallet purchase is spending.

Corrections have two lanes: admin-reviewed data rules reach phones without a release; engine or linking fixes need a failing golden case and a code release. AI drafts rules per redacted template; it does not publish shared rules or receive original SMS values. User-confirmed decisions take precedence.

## Verified integration state

Local integration branch: `sms-v2/main`, HEAD `064b548` when reviewed. Its worktree was clean. Nothing was pushed during this continuation.

| Work | Integration status |
| --- | --- |
| WP-00 golden harness and WP-01 contracts | Merged; contracts recorded frozen on 3 November |
| WP-02 engine and WP-03a–03d rule sources | Merged |
| WP-04 instruments and WP-07 categories | Merged |
| WP-05 linker | Merged (`d4a4cf7`) |
| WP-08 ingestion | Merged (`08c5a2f`) |
| WP-09 rule service | Merged (`cb05c0b`) |
| WP-06 ledger and projections | Not started in the index; interrupted worktree has no saved changes |
| WP-10–WP-17 | Not started in the index |

The interrupted bank and wallet fix worktrees also had no saved changes. The earlier Codex handoff worktree has been advanced to the integration HEAD. Its branch is `codex/sms-v2-wp04-07-08`; that name reflects the original request, not completed new work.

The shipped baseline is still the empty version-0 placeholder. Having rule source files merged does not mean a production-ready baseline has been built, signed, imported and shipped.

## Work saved before the documentation pause

An uncommitted rule-fix patch is isolated in the Codex handoff worktree. It is not merged into `sms-v2/main`:

- Finance hand-off keywords such as IPO and ASBA use whole-word regex guards instead of rejecting those strings inside merchant names.
- A GPAY sender and a Google Pay paid-notice rule emit a merchant and UPI reference without inventing an instrument. The sender uses the frozen enum's `other` value; `upi_app` is not in that enum.
- Regression tests reproduce the merchant-keyword and missing-notice failures.
- The linker golden test no longer exempts the duplicate-notice scenario.
- `WP-05-dup-notice-rules.md` has a local resolution note.

Checks actually run on this patch:

| Check | Result |
| --- | --- |
| New regressions plus linker golden test | 4 pass |
| Full domain suite | 989 pass, 0 fail |
| Rules lint | Clean |
| Golden linker scenarios | 8/8 expected pairs, 14/14 event scenarios, zero duplicate money legs |

These are linker and domain results, not an official ledger double-count score or a completed M1 gate. No ledger, phone-wiring or production change was made. Full app suites, API/database checks, regex parity and the complete golden CLI gate were not rerun for this patch before the pause.

## Existing decisions and integration details

Preserve the owner's accepted WP-08 decisions:

- Read `X-Sms-Sync-Has-More: 1|0`; the frozen response body has no `hasMore` field. Keep the optional contract request on record.
- Send history uploads with `?backfill=true`; do not add an undeclared body field. Backfill must not apply card rewards state.

Other handoff requirements:

- WP-14 must construct `RuleLinkContext` using recent facts, resolved instrument ids, open events and stored known events. Complete single-leg events can gain a later matching leg; context cannot contain only newly captured facts.
- `user_confirmed` events are protected. Event legs only grow. Replaying an input must not duplicate facts, evidence counts, ledger entries or rewards.
- Strip iOS filter tags before the existing contact-name/safety checks, retain the raw sender for the shared normaliser, and preserve `iosFilter` on the message. Test all five documented tag forms.
- Instrument ambiguity and rejection use `resolveDetailed`; the frozen `resolve` interface cannot return a review value. Limit history remains local metadata outside uploaded instrument JSON.
- Use `sms_v2_category.dart` for WP-07's public API. Category ids come from the existing catalogue, not constants. Read only user-confirmed category history.
- Bundle verification is owned by WP-13. WP-14 must not invent an allow-all verifier or accept an unsigned downloaded bundle. Version 0 remains the documented empty baseline exception.
- Follow WP-08's hook interfaces at call time. Refresh `api/sms_v2_assets/` after any approved contract or gates change.
- WP-09 publish needs passing golden evidence for the candidate bundle hash. Its real-database test fixture still needs reconciliation with the fully migrated schema.

## Requests and design questions to resolve deliberately

The request files are historical records; file presence alone does not mean the issue remains open. Code inspection confirms that POINTS parsing and the missing `balance_snapshot.asOf` fallback have already been implemented in the engine. The category fixture typo was already corrected on the integration branch. The no-amount failed-attempt case remains a documented contract/golden-set decision; do not fabricate an amount to satisfy it.

Before implementing the affected paths, reconcile these contract boundaries:

1. **Refund category persistence (WP-06/WP-07).** Refunds flow external → own and must reduce the original category's spending, but the frozen ledger validator forbids `category` when `to` is not external. Linked refunds may derive the category from their purchase. The standalone-refund fallback and persistence across reload/sync need an explicit contract-compatible design or a formal contract change request. Do not write an invalid refund ledger row or hide the issue in an unrecorded cache.
2. **Private provisional-rule delivery (WP-10/WP-14).** WP-10 asks sync to return `{templateHash, rule}`, while the frozen `aiResults` shape permits status and rule identifiers, not a rule body. Decide the delivery mechanism through the contract process before implementing an incompatible response.
3. **Sync freshness (WP-14).** The work package asks for newer-`updated_at` conflict resolution, while entity wire types omit that field. Specify how freshness is carried or tracked before assuming it is in entity JSON.

These are review questions recorded during documentation work, not approved contract changes. The playbook requires a request and an orchestrator decision before altering frozen schemas or signatures.

## Continuation sequence

1. Finish reviewing the isolated rule patch. Run bundle build/examples, regex parity and the golden harness, then integrate only with the required evidence. Keep the old parsers frozen.
2. Implement WP-06 in its own worktree from current `sms-v2/main`, with tests first. Build the projector and central totals, refund netting, transaction projection, namespace-scoped ledger storage, subscriptions/bills/investments/IPO/money-in adapters and guarded totals call sites. Include the specified `TxnEntryKind.refund` and `unknown` handling and exhaustive switches. Wire projector and category stages into the golden harness as an explicit integration task.
3. Run the complete M1 checkpoint. Every expected scenario total and category breakdown must match, official double counts must be zero, and required stages must be available. Keep environmental failures separate from unverified checks; do not label a gate passed when a stage is unavailable.
4. Continue M2 according to dependencies. WP-10, WP-12 and WP-13 are independent lanes after their prerequisites; WP-11 follows its APIs. WP-14 follows its listed M1 inputs and consumes the correction/security interfaces as they land. Complete verified-bundle, correction and provisional-rule integration before claiming the phone path complete.
5. WP-15 adds review/confirmation screens after phone wiring and corrections. WP-16 handles resumable replay, preserving user edits and manual rows, with a dry-run report. WP-17 cutover waits for every package, release gates, owner-reviewed migration and the tester period.

## Working discipline and release boundary

Continue the existing work-package workflow: isolated worktree, owned paths and listed touch points, failing tests first, focused checks during development, full suites at checkpoints, an evidence-based handoff and index update, then local integration in dependency order. Record deviations and requests rather than silently extending a package.

Keep all new app paths behind `SMS_PIPELINE_V2` and server routes behind the disabled-by-default flag until the planned rollout. Leave Gmail/email/IMAP and both card-discovery engines untouched. Do not edit applied migrations or generated files by hand; do not upgrade dependencies outside authorised touch points. Use synthetic or reviewed redacted fixtures only.

No push, deployment, production flag change, release or legacy deletion is part of this documentation checkpoint. The plan ships one user-facing release after its gates; an internal merge is not a release.

## Local integration and accuracy checkpoint

The owner designated `codex/sms-v2-wp14` as the integration line. Both it and `sms-v2/main` point to `b59d5bd`. The previous tip `01bd0a8` is preserved at `sms-v2/main-claude-backup`. An ancestry check confirmed that `ddd5e13`, `58d00ed` and `01bd0a8` are absent from the integration line.

The accuracy worktree is on `codex/sms-v2-real-accuracy`. From `tools/sms_rules_cli`, this command validated 1,505 examples across 724 rules, 27 ignore rules and 147 senders.

```sh
dart run bin/sms_rules.dart build --rules ../../rules/sms/v2 --created-at 2026-11-04T00:00:00Z --out <private-dir>/baseline.json
```

The repository extractor attempted a read-only connection to the local Messages archive. SQLite could not open it and a direct file open confirmed macOS denied access with `Operation not permitted`. No corpus was extracted. Family accuracy, double counts and review rate remain unmeasured. The subsequent signing, import, correction, device and cutover checkpoints wait on this ordered accuracy step.

### Real-corpus accuracy work (private)

A read-only local extract of a year of the owner's institutional messages stays on the owner's Mac and is never committed. Rule work is driven by redacting and clustering messages that no rule matched, then writing general rules. Each rule ships with a positive and a negative synthetic example, and the build, the golden gate and regex parity must pass before it is committed.

Fixes made so far: successful Zomato Money payments with the separate balance, PhonePe collect requests that are not debits, colon-delimited ICICI Info credits, CRED due reminders (extended to 17 issuers), ICICI transaction-password notices, ICICI one-time mandate holds and releases, and a Jio fraud-education notice. The unmatched share of the private corpus fell on every pass, but the labeled accuracy, full-pipeline double-count and review-rate gates are still open. Exact corpus counts and commands are kept in the private working notes, not here.

A stratified private sample for labeling and the labeled-accuracy scorer are the next inputs; neither is committed.

### Plan and placeholder audit

No tracked zero-byte files were found under the SMS v2 plans, phone or API implementation, or rule sources. The scan found no TODO or UnimplementedError markers in the phone and API feature directories. The shipped version-zero bundle is a deliberate placeholder until a signed candidate is verified. WP-17 has a specification and waits on its entry criteria, including seven tester days and a correction rate below 1%.

| Area | Evidence and remaining work |
| --- | --- |
| WP-00, WP-03, WP-07 | Synthetic gate passes. Review expected readings and categories in the private sample, then measure labeled accuracy and full-phone accounting on the corpus. |
| WP-06 | Refund category decisions are local metadata. Standalone cross-device refund category transport still needs an explicit design. |
| WP-08, WP-09, WP-11 | Migrated scratch database and category publication pass. Signed baseline import and verification, production rehearsal and live admin acceptance remain. |
| WP-10, WP-12, WP-13 | Consent, private draft delivery and corrections have local tests. Consent copy, production provider credentials, signing, App Check and the device security audit remain. |
| WP-14, WP-15, WP-16 | Focused integration tests passed 23 cases. Native acceptance for the final candidate, physical-device performance, restore during interrupted replay, and owner history review remain. |
| WP-17 | Cutover waits on the preceding gates and owner approval. |

The amount-less failed AutoPay case already has a recorded decision in WP-03c-attempt-without-amount.md. It goes to review under the frozen contract. Regex parity already runs in CI. The three WP-15 regression cases for replacement money facts, refreshed explanations and released IPO holds are present and passed.

From the integration checkout's app directory:

```sh
flutter test --no-pub --dart-define=SMS_PIPELINE_V2=true test/features/sms_v2/migration/legacy_replay_test.dart test/features/sms_v2/ui/review_actions_test.dart test/features/sms_v2/ledger/adapters_test.dart --reporter expanded
```

### Integrated candidate and local release rehearsal

The tested accuracy branch was fast-forwarded into the local integration line. The interrupted-replay regression was applied as f5c31e3. Both local integration refs included these changes.

The private corpus ran through the real phone runtime with an in-memory database, offline HTTP, original filter tags and a synthetic account. The replay stored matched, ignored and unknown source decisions, produced counted transactions and open review rows. Review rows may overlap across kinds and input rows may be filtered or deduplicated, so these counts do not establish the reviewed financial-message rate. This exercise measured behavior without determining correctness or a double-count rate.

The WP-16 dry run also ran on an in-memory copy populated through legacy offline capture. It reported duplicates merged and monthly transaction counts before and after. The test asserted that original rows were byte-for-byte unchanged as JSON. The before/after amounts and complete reports are private local artifacts. This is an offline reconstruction without the owner's actual account state, card bindings or prior edits.

The development bundle rehearsal built 744 rules, 30 ignore rules and 147 senders, and passed 1,546 examples. On a socket-only fully migrated Postgres cluster, `node api/scripts/import_sms_v2_rules.js --input <local-bundle> --admin-id <synthetic-owner>` inserted 744 rules and minted four signed cohorts. The second identical import inserted zero rules and minted zero bundles. The local-only connection used `NODE_ENV=test DB_SSL=false`. A temporary Flutter test passed signature verification, tamper rejection and all 15 phone scenarios using the signed bundle exported from Postgres. The ephemeral private key existed only in the import process environment. The temporary test harnesses were removed.

The candidate is still below the evidence required for rollout. Review expected readings in the private sample, investigate remaining unknowns and verify full-corpus linkage before using it for tester accounting. The production key and App Check owner steps are in ../runbooks/signing-keys.md. The actual device dry run, final native checks and seven-day tester gate remain.

### Approved draft-label evaluation

Commits 0f2c6d1 and a8d520d add the local scorer and rules for non-posting IPO notices, Kiwi card-payment evidence and pending collect requests. The owner approved the Claude-drafted labels for tuning. These labels are not independent ground truth. The 11 unsure rows are reported separately and were excluded from rule tuning.

From the CLI directory, build the version-zero local candidate with output `"$p/scored-pass5.json"`. Run `dart run tool/score_private.dart "$p/scored-pass5.json" "$p/label-sample.drafted.jsonl" "$p/score-pass5.json"` for engine results. Append `"$p/sample-pass5-phone.json"` as the fourth argument and use `"$p/score-pass5-phone.json"` as output to score the phone ledger effects. The scorer tests pass three synthetic ledger-effect cases. The candidate passed 1,554 rule examples, 115 golden cases, 15 golden scenarios and 46,620 regex parity comparisons with no mismatches.

The final phone comparison matches 139/316 sure rows, 1/11 unsure and 140/327 overall. It finds 64/222 unknown or unprocessed sure financial rows and 55 additional ignored sure financial rows. The engine-only comparison matches 131/316 sure and 132/327 overall, with 103/222 sure financial rows unknown. The remaining gaps are concentrated in IPO semantics and amounts, broker snapshots, refunds, subscription notices and instrument or amount mismatches. An informational IPO receipt cannot carry a printed amount in the frozen InfoFact contract. A Kiwi app receipt supplies evidence but does not independently prove a funding-account debit. The evaluation did not reach the stop thresholds.

Offline phone replays of the private corpus and the private sample were run through the real phone runtime. No reused money fact was found in multiple counted events. This invariant does not rule out distinct facts describing a duplicate real payment. No recognized card-bill or IPO event was marked as spending. The actual review share requires source-level attribution and an independently verified financial denominator. The per-kind amount comparison, all phone disagreements and the money subset are in the private evaluation directory. No private results are committed.

The current development bundle imported 748 rules into fresh scratch Postgres and minted four signed cohorts. Repeat import inserted zero rules and minted zero bundles. The earlier signed-bundle verification used the 744-rule candidate. The WP-15/WP-16 and phone scenarios passed 39 focused tests with each flag value. Full API ran 1,414 passed, four skipped and zero failed. The Android XML smoke passed using the synthetic app fixture. The detailed WP-17 deletion and entry checklist is in WP-17.md.

Final local checks on 6e8a6e7:

- `flutter test --no-pub --concurrency=1 --reporter expanded`, with and without `--dart-define=SMS_PIPELINE_V2=true`, passed 2,913 tests with four skips in each isolated checkout.
- `dart test --reporter expanded` in the CLI passed 41 tests. Static analysis of the scorer and its tests passed.
- The 748-rule exported scratch bundle verified under the app's BundleVerifier. A changed bundle version invalidated its signature. The verified bundle interpreted a synthetic PhonePe request as a pending attempt.
- Android: `flutter test integration_test/sms_v2_review_flow_test.dart --no-pub --flavor dev -d emulator-5554 --dart-define=SMS_PIPELINE_V2=true --dart-define-from-file=build/sms_v2_smoke_defines.json --reporter expanded` passed the XML-to-review and totals smoke.
- iOS: `PANDAPAY_SIMULATOR=1 flutter drive --driver=test_driver/sms_v2_review_driver.dart --target=integration_test/sms_v2_review_flow_test.dart --no-pub -d 465049B3-1FCA-41CB-9F98-5B59686EBA72 --dart-define=SMS_PIPELINE_V2=true --dart-define-from-file=build/sms_v2_smoke_defines.json` passed two tests on iPhone 17 with iOS 26.5. The fixture feeds a filter-tagged sender through the Shortcut batch adapter. It does not exercise a real Shortcut automation.
- The final replay attached open review rows to 721 distinct sources out of 4,097 distinct corpus sources (17.6%). On the draft sample, 64 of 222 sure financial rows attached to an open review item (28.8%). The corpus denominator includes non-financial input. The sample is stratified and these raw rates are not population estimates.

Owner spot-check files are local. The phone report lists every disagreement by zero-based index, with a money-only subset and 17 label adjudication candidates. Those candidates cover registrar instructions versus actual releases, application amounts that cannot be represented by InfoFact, and Kiwi receipts without a funding leg. The supplied labels are unchanged.

### Refund follow-up

Commits 67d8689 and b42c89f add posted Federal card refund/reversal variants and dated HDFC card refund alerts. Synthetic notices returned unknown before the changes. The new examples separate completed credits from initiated refunds and future reversals. Federal notices without a printed suffix do not invent one.

From the CLI directory, build with output `"$p/refunds-v0.json"`, then run `dart run tool/check_pipeline.dart` and `node test/regex_parity.mjs`. The build passed 1,562 examples for 752 rules, the golden gate passed 115 cases and 15 scenarios, and parity passed 46,860 comparisons with zero mismatches. The offline phone harness replayed the full corpus and draft sample with the new bundle. Score with `dart run tool/score_private.dart "$p/refunds-v0.json" "$p/label-sample.drafted.jsonl" "$p/score-refunds-phone.json" "$p/sample-refunds-phone.json"`.

All five targeted sure rows now agree with the drafts. The refund stratum rose from 10/32 to 15/32, and overall sure agreement from 139/316 to 144/316. The sure financial unknown or unprocessed count fell from 64 to 59 of 222. Full replay produced 1,037 counted transactions and 738 open review rows. No money fact was reused across counted events. The narrower invariant does not establish zero duplicate payments. The 752-rule build still needs the signed scratch import and candidate-level release verification. No production or physical-device changes were made.

### Phase 1 isolated iPhone rig

- T1: `node scripts/sms_v2_local_rig.js --check-only` passed on fresh scratch Postgres. It migrated both databases, imported 752 rules, minted four signed cohorts and started both real services. HTTPS OTP login, rules fetch, tamper rejection, facts upload and ledger read-back passed. The live rig also passed the app-client smoke using AuthApi and SmsV2Runtime over the rig CA.
- T2: each rig generates an ephemeral Ed25519 key. Only Debug development builds accept the supplied test public key. The production anchors are unchanged. Dart BundleVerifier rejected a tampered server response in the app-client smoke.
- T3: `python3 scripts/build_sms_v2_local_ios.py <rig> --simulator <uuid>` built and installed the distinct Debug app on a dedicated iPhone 17 simulator. This verified the recipe and installation. Interactive sign-in on the simulator and cable installation on the physical iPhone were not performed.
- T4: tests exercised all five filter tags and the live gate with a tagged bank handle, a personal phone handle and missing sender evidence. The live adapter preserves missing identity instead of fabricating an issuer. The actual Shortcut automation remains a physical-device check.
- T5: the runtime replays synthetic IPO, salary and subscription history into the five screens. The widget smoke exposed and now covers the Money in display honoring an explicit salary fact.

From app, with a live default rig:

```sh
SMS_V2_LOCAL_RIG=/tmp/pandapay-sms-rig.EXAMPLE flutter test --no-pub --concurrency=1 --dart-define=SMS_PIPELINE_V2=true test/features/sms_v2/pipeline/local_rig_test.dart test/features/sms_import/ios_shortcut_sms_test.dart test/features/sms_v2/ui/history_screens_test.dart test/features/sms_v2/ledger/adapters_test.dart --reporter expanded
```

All 19 tests passed. The local runbook has the simulator and later physical-device instructions. No shared service or physical phone was changed.

#### USB signing and install attempt

Xcode Settings showed the signed-in Personal Team. The command-line build still reported `No Accounts` when requesting new profiles. Building Runner in Xcode with the wired iPhone selected created development provisioning profiles for the separate `app.pandapay.pandapay.smsv2rig` app and widget. The Debug build succeeded, and `codesign --verify --deep --strict` passed for the app bundle. The rig health endpoint also returned 200 with its test CA.

Xcode Run reached the install step. iOS rejected the app because the phone already had three apps installed with a free developer profile. The existing apps stayed installed, and the temporary build settings were restored. The owner can free a development-app slot before the next USB attempt. Physical sign-in, sync and the Shortcut smoke remain unverified.

The USB retry installed the distinct Debug app alongside the regular app. The test build omits the regular app's URL scheme, so saved Shortcut actions keep their existing app bindings. A later reinstall stalled while the prior Debug session was attached. Terminating that Debug process unblocked installation. The restarted build reported a resumed main isolate, a rasterized first frame, and a rendered `WelcomeScreen` through Flutter's on-device inspector.

The Debug build now trusts the scratch CA only for the rig's configured private HTTPS origins. It rejects other origins and does not follow redirects. The host app-client test confirmed OTP, rule verification and fact sync through that transport. With `SMS_V2_LOCAL_RIG` set to the live scratch directory, `flutter test --no-pub --concurrency=1 --dart-define=SMS_PIPELINE_V2=true test/features/sms_v2/pipeline/local_rig_test.dart test/features/auth/signup_test.dart test/features/auth/versioned_otp_client_test.dart test/features/sms_import/ios_shortcut_sms_test.dart test/features/sms_v2/ui/history_screens_test.dart --reporter expanded` passed all 27 tests. The owner still needs to complete sign-in on the installed Debug app and verify physical-device sync and Shortcut delivery.

The first certificate-scoped build failed on the phone during trust setup with `BAD_PKCS12_DATA`, before sending an auth request. Loading the original PEM bytes fixed the failure in the installed Flutter/Dart runtime. The rebuilt Debug app used the same transport to receive HTTP 200 from `/ready` and `/health` on the physical iPhone. The app-client integration test and targeted Dart analysis passed again. The temporary phone probe only made readiness requests and was kept outside the repository.

#### Phase 1 physical-device follow-up

The owner completed login on the local Debug app. Auth returned 200 for the email request and verification, and the API created the scratch profile with 201. Moving the app into the background exposed a native crash because the headless engine registered message handlers before `run`. The engine now starts before plugin and channel registration. The rebuilt device app launched, and the four Dart background-processing tests and both native intake/sender harnesses passed.

The physical acceptance test remains unverified. The first run invalidated its runtime while catalogue/category providers loaded. Later runs failed at `GET /profile` with `No route to host` for the Mac's LAN address. The API remained healthy on the Mac. The owner requested manual phone instructions with diagnosis from logs. The normal Debug entry point is being restored after the acceptance attempt. Real-message replay and native Shortcut acceptance remain pending.

### Explicit historical category checks

The owner asked why previously synced/imported history did not visibly use newer SMS rules, and requested a deliberate refresh that does not repeat on each sync. Worktree `codex/sms-v2-history-recheck` started from `d8e6edd`; implementation commits are `04ad071`, `584574a` and `a4af434`.

The Debug action previews a chosen period on a private memory copy, then requires an explicit apply. It checks newly retained legacy sources through the existing pipeline, and refreshes automatic categories from stored v2 events/facts. Durable small chunks preserve account boundaries, corrections, custom categories, notes, tags and deletions. Unsent original money records wait for sync. Category-only uploads use a restricted server endpoint and never reapply card reward state. A pulled purchase correction refreshes linked refunds, including a second user correction.

Already-matched v2 facts remain immutable; this action does not reparse those messages or relink their events. A versioned replacement/retirement sync protocol is required for that broader migration. Its proposal, release controls and manual phone checklist are in `../history-recheck-plan.md`. No changes in this batch were installed on the iPhone or deployed to the running server. No owner messages were added to the repository. Accuracy targets and physical acceptance remain open.

The reproducible commands, failure-first evidence, scope limits and final validation counts are recorded in `WP-16-history-recheck.md`.
