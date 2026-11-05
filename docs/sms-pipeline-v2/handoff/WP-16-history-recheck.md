# Controlled history refresh — local evidence

Implementation commits: `04ad071`, `584574a` and `a4af434`, on `codex/sms-v2-history-recheck`, based on `d8e6edd`. No deployment, push, production flag/key change, Gmail edit or phone installation is part of this batch.

## Result and limits

The Debug app has a date-bounded preview/apply action. It checks newly retained legacy sources through the existing full pipeline and refreshes automatic categories on stored v2 events. Ordinary sync or a new bundle does not schedule this maintenance. A completed category request does no additional writes. Personal rules and category corrections create a different explicit request fingerprint.

Preview uses an asynchronous SQLite backup into memory. Apply commits at most 25 category targets per chunk by default, with a hard maximum of 50. Checkpoint, ledger, display and outbox changes commit together; the event loop yields between chunks. Pause, interruption and account changes retain committed progress. Two requests for the same account serialize.

The server's new `POST /sms/v2/categories:batch` uses the facts-batch schema with empty source, instrument and event arrays. It keeps the existing feature, membership, attestation, rate and ownership gates. It updates existing categories only, preserves newer money readings and user categories, and does not reverse/apply rewards or card state. Stale category submissions cause canonical ledger rows to be re-emitted for the next pull. Older APIs return 404 and leave the category queue pending.

Category updates preserve custom display categories, corrected money, notes, tags, manual entries and deletions. An unsent money upload waits for sync rather than being replaced by a category-only upload. Purchase/refund categorization stays consistent across selected-date boundaries and across devices, including repeated user corrections.

Already-matched v2 facts are immutable and are **not reinterpreted** by this action. A full historical extraction/linking replacement requires a versioned generation/retirement sync contract and rollback protocol. The proposal is in `../history-recheck-plan.md`; do not treat category refresh as completion of that protocol. Missing raw text remains unverified. None of these tests establishes real-message accuracy or the absence of duplicate real-world payments.

## Tests first

Private local logs recorded failures before each corresponding fix:

- `/tmp/history-recheck-red.log`, `/tmp/history-late-migration-red.log`, `/tmp/history-upload-red.log`, `/tmp/history-server-red.log`: missing maintenance operations and endpoint behavior.
- `/tmp/history-scope-red.log` and `/tmp/history-scoped-report-red.log`: date-bounded requests drained sources outside the chosen period and reported unbounded coverage.
- `/tmp/history-custom-server-red.log`, `/tmp/history-cross-device-red.log`, `/tmp/history-sync-custom-red.log`: custom categories and cross-device refund context were lost.
- `/tmp/history-unsent-red.log`: a refresh did not defer an unsent original money upload.
- `/tmp/history-personal-key-red.log`: a completed checkpoint hid a later personal category rule.
- `/tmp/history-refund-user-red.log` and `/tmp/history-refund-local-red.log`: an inherited user refund decision became stale after a second purchase correction.
- `/tmp/history-preview-baseline-red.log`: a repeat explicit check compared with the original migration baseline instead of the current account.

Only synthetic cases and implementation are committed. No owner messages were copied into this worktree.

## Verified commands

From `app`:

```sh
flutter test --no-pub test/features/sms_v2/migration/history_category_recheck_test.dart test/features/sms_v2/migration/legacy_replay_test.dart test/features/sms_v2/sync/sync_pull_test.dart test/features/sms_v2/sync/facts_upload_test.dart test/features/sms_v2/ui/history_update_panel_test.dart
```

38 passed on `a4af434`. The focused run processed 1,003 synthetic events in 517 ms, over 41 chunks. Its longest chunk including initial setup was 28.966 ms, with 81 timer ticks during the job. This is a desktop test result, not an iPhone frame-time guarantee.

From `api`, with local dependencies installed and `SMS_V2_TEST_DATABASE_URL` pointing to the disposable local rig database:

```sh
node --test --test-concurrency=1 test/sms_v2/*.test.js
npm test
```

The SMS v2 suite passed 136, skipped 3, failed 0 against the migrated scratch database. The skips require the separate private-admin database connection; those tests clear published bundles and were not pointed at the running phone rig. The existing rules HTTP fixture now allows a development bundle already present in the database. The category route passed an actual gzip HTTP submission, response validation and incremental sync read-back. The full API suite passed 1,414, skipped 4, failed 0.

Targeted `dart analyze` over all changed SMS implementation/test files passed with no issues. From `tools/sms_rules_cli`, `dart run tool/check_pipeline.dart` passed all 115 cases and 15 scenarios, including lint and examples. `node test/regex_parity.mjs` passed 46,860 comparisons with zero mismatches.

Full app validation on `584574a`, in separate worktrees with separate temporary directories:

```sh
TMPDIR=/tmp/pandapay-history-test-off flutter test --no-pub --concurrency=2 --reporter expanded
TMPDIR=/tmp/pandapay-history-test-on flutter test --no-pub --concurrency=2 --dart-define=SMS_PIPELINE_V2=true --reporter expanded
```

Both passed 2,936, skipped 5, failed 0. Logs are `/tmp/history-recheck-full-off-final.log` and `/tmp/history-recheck-full-on-final.log`. The initial full runs caught the stale inherited user refund and a home navigation test tapping during a scroll animation. Both now have focused passing regressions. Earlier full runs on a live-editing tree were discarded as final evidence; the repeated flag-on run used a separate detached worktree at the frozen commit.

The final report-only follow-up `a4af434` changes the baseline of explicit bounded requests; the stored global migration report is retained. Its new assertion failed before the fix. All 38 focused tests and targeted analysis passed afterward. The complete SMS v2 suites with each flag value were repeated on this follow-up; the counts are recorded below. The entire app suite was not repeated after this narrow follow-up. There are no new dependency or applied-migration changes.

```sh
TMPDIR=/tmp/pandapay-history-test-off flutter test --no-pub --concurrency=2 test/features/sms_v2 --reporter expanded
TMPDIR=/tmp/pandapay-history-test-on flutter test --no-pub --concurrency=2 --dart-define=SMS_PIPELINE_V2=true test/features/sms_v2 --reporter expanded
```

Both final SMS v2 runs passed 256, skipped 2, failed 0 on `a4af434`. Logs are `/tmp/history-recheck-v2-off-final.log` and `/tmp/history-recheck-v2-on-final.log`. The skipped cases require explicit local-rig/native test setup; these runs do not substitute for the owner's actual history or Shortcut acceptance.

## Device acceptance

On 5 November 2026, the owner requested installation. A signed Debug build 106 containing the integration at `a3af62f` was installed over the existing `app.pandapay.pandapay.smsv2rig` app by USB. `codesign --verify --deep --strict` passed, devicectl confirmed build 106, and Flutter launched it with a running Dart VM service. The regular app stayed at build 109. The Debug manifest omits the regular app's URL scheme, retaining the existing Shortcut bindings. No app container was deleted, and temporary Xcode project/manifest changes were restored.

The local API was restarted to load the category endpoint. The original rig supervisor stopped its sibling services when its API exited. The services were restored using the existing Postgres data, HTTPS origins, CA and SMS bundle signing key. Local auth refresh and lookup keys had to be regenerated; phone equality hashes were refreshed locally without changing user IDs or contact values. Existing local sessions may require email sign-in again with the test OTP. No hosted service was changed. Resumption files, private environment, PID files and build/device logs stay under `/tmp`; they are not committed.

Both HTTPS readiness endpoints returned 200 after restoration, and the category endpoint enforced authentication with 401 for an anonymous request. This establishes installation, launch and Mac-side service readiness. The physical history check, phone-to-Mac sync and phone performance remain unverified. Follow `../history-recheck-plan.md`, reviewing the preview before applying.

Production migration approval, complete matched-fact reprocessing, real-message accuracy targets, production keys/App Check and real-phone Shortcut/history acceptance remain separate gates. Existing owner approval to test locally does not change shared rollout flags.

## White-screen follow-up — standalone local iPhone build

The owner reported a white screen after build 106. The Mac's local API and auth readiness endpoints both returned 200, but the Debug process had stopped with SIGKILL before an API request. A direct launch captured the native Flutter diagnostic: a Debug engine cannot start on iOS without Flutter tooling or Xcode. It then exited with signal 11. This reproduced the Home Screen launch failure independently of backend requests.

The local defines file also lacked the CA field at this point. Its public CA was restored from the existing rig certificate before the next build. No new CA, SMS signing key, database or production flag was created.

Commit `615f652` adds an explicitly opted-in local Profile build and the physical-device build/install recipe. It reuses the installed test bundle identity and omits the regular Shortcut scheme. Local TLS, development bundle trust, test App Check provider and history controls require exact dev environment, both public anchors and a Profile opt-in. Release builds cannot enable this path. The HTTP client retains the existing private-origin and redirect restrictions. Production anchors and release App Check providers remain unchanged.

Test-first log: `/tmp/sms-v2-standalone-red.log` failed before the build policy existed. With the local rig running, from `app`:

```sh
SMS_V2_LOCAL_RIG=/tmp/pandapay-sms-rig.EXAMPLE flutter test --no-pub --concurrency=2 --dart-define=SMS_PIPELINE_V2=true test/features/sms_v2 test/app/local_sms_rig_build_test.dart
flutter test --no-pub test/app/local_sms_rig_build_test.dart test/features/sms_v2/sync/bundle_verifier_test.dart test/features/sms_v2/sync/attestation_test.dart test/features/sms_v2/ui/history_update_panel_test.dart
flutter test --no-pub --dart-define-from-file=/tmp/pandapay-sms-rig.EXAMPLE/flutter-defines.json --dart-define=SMS_V2_LOCAL_TEST_BUILD=true test/app/local_sms_rig_build_test.dart
```

The full focused suite passed 266, skipped 1, failed 0, including live app-client login, signed rule verification, tamper rejection and fact sync. The smaller regression suite passed 17. Commit `b96c1fb` adds the compiled-configuration transport check; with the rig defines all 10 policy/transport cases passed, including real HTTPS readiness for both services and rejection of an unrelated origin. Targeted static analysis passed with no issues. The Python recipe rejected three invalid target/build argument combinations before any build and passed compilation.

The checked-in recipe built and installed Profile build 107 as **PandaPay SMS v2 Test** on 5 November 2026. Code signature verification passed, devicectl confirmed the installed version, and the app launched without Flutter or Xcode attached. The regular app remained at build 109. Temporary Xcode/manifest/lock changes were restored.

After that cold launch, the phone completed email sign-in and received successful API responses for transactions, cards, Home and other account data. The local API also recorded `GET /sms/v2/sync` with HTTP 200 from the app. This verifies phone-to-Mac HTTPS and authenticated SMS v2 sync for this standalone build. The saved local data was not deleted. A later manual history preview/apply, Shortcut automation and full history acceptance remain owner checks.

Build/install log: `/tmp/sms-v2-standalone-profile-build.log`. The Debug failure, device inventory, service and test logs remain local under `/tmp`. The earlier claim of a running Debug VM did not establish Home Screen relaunch acceptance; build 107 supersedes that artifact for manual testing.
