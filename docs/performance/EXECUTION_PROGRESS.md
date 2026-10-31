# Performance engineering execution progress

Updated 31 October 2026. Branch `codex/ios-shortcuts-prototype`, ahead of origin by commit `c2479722`. Preserve unrelated untracked `.qoder/` and `vibe_images/`. Read this file, `PERFORMANCE_BASELINE.md`, `PERFORMANCE_AUDIT.md` and the real-world test matrix before resuming.

## Completed

- Environment: Flutter 3.44.8, Dart 3.12.2, DevTools 2.57.0, JDK 17, Android SDK and API 35 emulator confirmed; `integration_test` already in pubspec. No Flutter Codex plugin verified/installed. Doctor warning: some Android licenses unaccepted; profile builds work.
- Architecture audit: Riverpod/go_router, cache-first Home, SMS capture worker and provider-ID checkpoint, sync engine, synchronous sqlite3 FinancialStore, duplicate full transaction fetch paths documented.
- Baseline: one verified process-cold Recents swipe launch reached Home at 11.77 s from Dart main, with onboarding preference at 8.25 s and secure first read at 11.30 s. Three later guaranteed cold runs reached Home at 1.33, 1.32, 1.82 s. One logged 67 skipped Android frames. Another process-cold run reported Android activity display at 9.66 s while Dart-to-Home was 1.68 s, showing a separate pre-Dart delay. Profile build 71 cold run took 5.78 s Dart-to-Home. This variability is unresolved; no physical device or reliable UI/raster scroll trace yet.
- Commit `c2479722`: profile startup markers, SMS gate coalescing, removal of broad Home invalidation after sync materialization. Its Activity/Spending previous-data retention was later judged insufficiently account-fenced; uncommitted follow-up explicitly disables it pending a safe provider design.
- Uncommitted scoped work: FinancialStore SQL filter for already repaired provisional rows; repository-instance identical-query transaction single-flight; Home first-frame timing marker; test matrix/audit/setup/baseline docs. FinancialStore 51 tests and single-flight 2 tests passed; integrated Activity/Spending/FinancialStore/single-flight run passed 114 tests after an Activity test timing correction.
- The parallel token-read experiment was tested in profile build 72: both reads completed together at 8.19 s and Home first frame was 9.71 s from Dart main, so it produced no demonstrated gain and was reverted.

## Unresolved

- Capture Android main-thread and Flutter CPU/frame traces around the rare 11.77 s launch; repeat swipe-away with PID verification. Do not blame secure storage alone because SharedPreferences also stalled.
- Measure scroll/navigation UI and raster p95/p99, CPU, memory, DB spans, request counts under SMS/sync workload on emulator and representative physical Android device. No smoothness claim is supported yet.
- Three Subscriptions suite mandate/date expectation failures are confirmed on committed HEAD `c2479722` with no current screen/test diff. Track as a separate product regression; do not call the whole suite green.
- Transaction reads still invoke repair hooks; full save and JSON conversion use synchronous sqlite3 on UI isolate. Profile 3k/10k rows before worker-owned DB design; preserve cursor and receipt atomicity.
- Home refresh can finish before cache-first transaction network refresh, then invalidate reports. Repository single-flight only deduplicates identical requests on one repository instance. Define account-scoped refresh owner and publication semantics.
- SMS coalescer can still schedule a second broad pass. Measure due work, backlogs, AI polls, account switches and frame overlap before splitting jobs.
- Account-safe stale-content retention for Activity, Spending, Wallet and Subscriptions needs namespace/query keyed data ownership and tests. Current safe loading behavior can flicker.
- Existing `integration_test/security_storage_key_test.dart` was attempted against the connected emulator; Gradle spent 141.2 s and failed to produce an APK. Integration execution needs a separate Gradle/build investigation before it can be a release gate.

## Immediate next actions

1. Review and test current dirty diff, then commit only scoped, passing changes. Keep unrelated user files untracked.
2. Triage the three pre-existing Subscriptions mandate/date failures separately; add account-switch regression tests before restoring previous-data retention.
3. Capture profile VM/Android thread traces for the long startup and frame timing during representative scrolling.
4. Implement one measured DB/refresh fix at a time, rerun the same scenario, and record before/after in `FINAL_PERFORMANCE_COMPARISON.md` only when measured.

No source change or device test in this project should be represented as a completed performance improvement without a comparable before/after trace.
