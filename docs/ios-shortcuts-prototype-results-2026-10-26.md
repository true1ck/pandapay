# iOS Shortcuts simulator prototype

Tested 26 October 2026 on branch `codex/ios-shortcuts-prototype`, created from local `dev` at `8d12a3324153bcb2bef9afe651138b313f7abc17`. These are simulator results, not a claim of Android-equivalent SMS capture.

Follow-up: the [100-message history batch experiment](ios-history-prototype-100-messages-2026-10-26.md) now demonstrates 75 financial observations, OTP/noise filtering and duplicate-free replay. Apple Messages acquisition still returned zero results in the simulator.

## Result

The **Apple Shortcuts → native PandaPay App Intent → durable local capture → existing Dart financial parser → prototype screen** path works. Three synthetic financial messages were captured by running a real Shortcut in Apple's Shortcuts app and subsequently displayed in PandaPay. No database, authentication service, API or backend was used or changed.

**Messages history acquisition remains unverified.** The simulator exposes Find Message, but its search returned zero results even without filters. A synthetic text entered into the simulator's Messages app was visible there but was not returned by Find Message. It was an outgoing simulator test bubble, not an incoming carrier SMS. Directly supplying fixture text in Shortcuts proved the handoff and parsing; it did not prove automatic SMS receipt or history access.

## Test environment

- Dedicated simulator: **PandaPay iOS Shortcuts Prototype**, iPhone 17 Pro, iOS 26.5 (23F77).
- Simulator UDID: `2FA7AFA2-B8AE-4952-AEB5-2795373C7D9A`.
- Xcode 26.6 (17F113), Apple Silicon simulator build (`arm64`).
- App bundle: `app.pandapay.pandapay`; entry point: `app/lib/main_ios_import_prototype.dart`.
- Installed runtimes were iOS 26.4 and 26.5. No iOS 27 notification-trigger test was performed.

## Observed checks

| Check | Observed result |
| --- | --- |
| Real Shortcuts action discovery | PandaPay's Capture Bank Message (Prototype) action appeared in the system Shortcuts app. |
| Debit fixture | ₹349.00 transaction, merchant BUNDL TECHNOLOGIES. |
| Credit fixture | ₹5,000.00 transaction. The existing parser labels the counterparty `your HDFC Bank A/C *9080`; this prototype does not change parser heuristics. |
| Statement fixture | ₹900.00 bill, due 30 October 2026. |
| Exact debit replay with original date | Returned the same capture ID; did not add another record. |
| OTP fixture | Shortcuts showed “Sensitive test message rejected before storage.” The inbox remained at three financial captures. |
| PandaPay terminated before running capture Shortcut | The native action completed and returned the same debit ID without opening the Flutter screen. |
| App reopened | UI showed **Native captures: 3 / Financial observations: 3**, including the original fixtures. |
| Timestamp mapping | `26 Oct 2026 09:30` entered in Shortcuts was interpreted in simulator local time, producing `2026-10-26T04:00:00Z` (IST → UTC). Capture time is stored separately. |
| Find Message, body contains PANDAPAY_TEST | Count = 0. |
| Find Message, no filters | Count = 0. |
| Focused Dart tests | All 4 passed: financial parsing, shared-parser OTP gate, synthetic marker requirement, preservation of original receive time. |
| Targeted Dart analysis | No issues found. |
| Native + Flutter simulator build | Xcode BUILD SUCCEEDED. |

The sample fixture bodies are in `app/test/fixtures/ios_shortcuts_messages.json`. Native captures are persisted in this app's Application Support directory as `ios-shortcuts-prototype.json`. The three manually exercised financial fixtures used the same explicitly supplied sender/date; their different bodies distinguish them. Repeating the same sender/date/body preserves one record. Missing original dates deliberately use separate IDs rather than collapsing equal-text real events.

### Android OTP comparison

Follow-up source review confirmed that Android drops OTP/security messages before capture and parsing; it does not salvage their merchant or amount. `SmsGateFilter` explicitly rejects an existing fixture containing an OTP for **Rs 4,500 at Amazon**. `SmsImportStore._capture` returns immediately for sensitive triage, before the intake write and financial parser. The foreground listener, background handler and inbox reader apply the same OTP/security rejection. The canonical parser also returns null for sensitive input.

The Android gate, triage and inbox-page suites were run alongside the iOS prototype suite: **69 tests passed**. For the exercised OTP case, iOS therefore matches the existing Android behavior. Retaining only merchant/amount from an OTP would be a new feature on both platforms. Such an event would need a separate unconfirmed-attempt state, exclusion from spending totals and reconciliation with evidence of a completed payment; an authorization code request alone does not establish that the purchase completed.

## Try the installed demo

Open the dedicated simulator and Apple's Shortcuts app (Home → Utilities → Shortcuts). Three saved workflows are available:

1. **PandaPay Capture Fixture**: Text containing the tagged debit fixture → Capture Bank Message (Prototype). The action's Message text is the Text action's output variable, Sender is `VM-HDFCBK`, Received at is `26 Oct 2026 09:30`. Run, dismiss the confirmation, then open PandaPay to inspect the parsed result. Re-running the fixed fixture leaves the count unchanged.
2. **PANDAPAY OTP Rejection Probe**: the same native action with the tagged synthetic OTP fixture. Running it should show the expected rejection dialog and retain no OTP in the native inbox.
3. **PANDAPAY History Probe**: unfiltered Find Message → Count. It currently returns 0 on this simulator. During testing, adding a Body contains PANDAPAY_TEST filter also returned 0.

To try another financial body, edit the Text action in the capture fixture workflow, retain the `[PANDAPAY_TEST]` marker, and supply its original sender/date. Open or refresh PandaPay after running it. The screen parses and displays observations locally; it does not write transactions to the production financial store.

## Implementation boundaries

- The native prototype and App Intent are compiled only under `DEBUG && targetEnvironment(simulator)`. The separate Dart entry point also requires an iOS Debug build; the native channel is unavailable on devices and release builds.
- The regular app entry point and Android intake are unchanged. The simulator bridge is registered alongside the existing simulator plugin registrant.
- The queue accepts tagged synthetic messages only, rejects OTP patterns before storage, limits body size to 20,000 characters and retains at most 200 records.
- The queue is an atomic JSON file for disposable synthetic data, not a production encrypted inbox. Its in-process lock and replay key are insufficient evidence of production cross-process or cross-source reconciliation guarantees.
- Parsing occurs when the prototype screen opens or refreshes. Background capture is proven; immediate background Dart parsing is not.
- Original sender/date are explicitly supplied in this test. Automatic extraction of those fields from the Messages action output remains untested.
- No personal Message automation was configured to forward real content. No notification automation, real carrier delivery, locked-device run, reboot recovery or large-history pagination was validated.

## Rebuild and verify

Use the project's Flutter SDK on PATH. From `app`:

```sh
flutter test test/data/ios_import_prototype_test.dart
dart analyze lib/data/ios_import_prototype.dart lib/main_ios_import_prototype.dart test/data/ios_import_prototype_test.dart
PANDAPAY_SIMULATOR=1 flutter build ios --simulator --debug --no-codesign --target lib/main_ios_import_prototype.dart
```

The generic Flutter simulator command produced an x86_64 app with the current toolchain; that cannot install into this arm64 simulator. Flutter's device-specific run built arm64 successfully but then failed while looking up TARGET_BUILD_DIR. The working installation came from a direct Xcode build. After dependencies have been generated by the command above, from `app/ios`:

```sh
PANDAPAY_SIMULATOR=1 xcodebuild \
  -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator \
  -destination id=2FA7AFA2-B8AE-4952-AEB5-2795373C7D9A \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  FLUTTER_TARGET=lib/main_ios_import_prototype.dart \
  BUILD_DIR="$PWD/../build/ios" build
```

From `app` install and launch:

```sh
xcrun simctl install 2FA7AFA2-B8AE-4952-AEB5-2795373C7D9A build/ios/Debug-iphonesimulator/Runner.app
xcrun simctl launch 2FA7AFA2-B8AE-4952-AEB5-2795373C7D9A app.pandapay.pandapay
```

`PANDAPAY_SIMULATOR=1` uses the existing project mode that omits ML Kit and Rive native pods unsupported by this simulator configuration. It is not a device/release build mode. CocoaPods/Flutter may rewrite generated dependency files during this mode; those incidental lockfile changes are excluded from this prototype's source changes.

## Next decision

Keep the Shortcuts adapter as a feasible integration candidate. A physical iPhone experiment must establish whether real incoming bank texts and historical messages supply full body/sender/date, and whether execution survives locking, closure, interruption and offline use. This branch intentionally needs a separate device-safe storage/configuration step before that test. The successful simulator handoff does not establish exact Android functionality on iOS.

See the earlier [platform feasibility research](ios-financial-import-options-2026-10-26.md) for the Apple sources and the broader parity checklist.
