# 100-message iOS history prototype

Tested 26 October 2026 on `codex/ios-shortcuts-prototype`, based on `dev`. All examples are invented and tagged `[PANDAPAY_TEST]`. Backend services and production data were not changed.

## Observed result

The historical **batch handoff and financial detection work** in the iOS 26.5 simulator. A real two-action Apple Shortcut read a separately seeded 100-message synthetic inbox and passed its JSON output to PandaPay's native import App Intent. PandaPay subsequently showed **75 financial observations**, preserving the July–October original dates.

**Reading the Apple Messages history remains blocked in this simulator experiment.** The bodies of all 100 samples were also entered through the simulator Messages UI into its mock conversation. Running an unfiltered Find Message → Count shortcut still returned **0**. These visible bubbles are outgoing mock messages stamped with today's UI timestamp, not incoming carrier messages. Their presence does not establish that the operating system's history provider has indexed equivalent SMS records. The successful batch did not use those search results or silently fall back to fixtures.

This result proves processing of supplied historical evidence, not access to an existing iPhone inbox or complete Android parity. A physical iPhone test is still required for actual Apple Messages acquisition, field mapping, pagination and permissions. iOS 27 was not exercised because the installed runtimes were 26.4 and 26.5.

## Corpus and results

The reusable generator is `app/lib/data/ios_import_prototype_fixtures.dart`. Its checked-in JSON output is `app/test/fixtures/ios_shortcuts_history_100.json`. Original dates run from **18 July through 25 October 2026**, at 04:00 UTC (09:30 IST).

| Input category | Count | Observed handling |
| --- | ---: | --- |
| Card debits | 40 | Parsed as transactions |
| Bank credits | 20 | Parsed as transactions |
| Credit-card bills | 15 | Parsed as bills with due dates |
| OTPs mentioning an amount/vendor | 10 | Rejected by the native capture gate before writing capture records |
| Promotions | 10 | Excluded by the shared Android triage |
| Unrelated parcel messages | 5 | Excluded by the shared Android triage |

Native capture is deliberately a small synthetic transport queue: it retained 90 non-OTP inputs, of which 75 produced financial observations. The other 15 are synthetic noise, not financial records. The input fixture file itself contains the explicitly invented OTP examples so the rejection can be tested; none were retained in the native capture output.

First actual Shortcuts execution:

```json
{"scanned":100,"added":90,"duplicates":0,"sensitive":10,"invalid":0}
```

After terminating PandaPay and running the same Shortcut again:

```json
{"scanned":100,"added":0,"duplicates":90,"sensitive":10,"invalid":0}
```

The native inbox remained at 90 unique records and the reopened app displayed **Financial observations: 75**. Two deliberately identical debit bodies on different original dates retained separate native IDs. All native IDs were checked against the sender/date/body SHA-256 identity, and all retained records had a known original date.

The interrupted UI-seeding operation was resumed from its visible last draft. The mock conversation may contain an extra replay bubble in addition to the 100 distinct fixture entries and the earlier single-message test. The controlled dated input file contains exactly 100 records, and native replay handling was tested independently of the UI bubble count.

## Run the installed demo

Dedicated simulator: **PandaPay iOS Shortcuts Prototype**, iPhone 17 Pro, iOS 26.5. UDID: `2FA7AFA2-B8AE-4952-AEB5-2795373C7D9A`.

1. Open PandaPay. Its prototype screen has **Seed 100 older demo messages** and **View the 100-message demo inbox**. Seeding writes the dated synthetic input to the app's Application Support directory; it does not grant or simulate Apple Messages permission.
2. For a clean repeat, use **Clear imported synthetic results**. This clears the disposable capture output only, leaving the input fixture available.
3. Open Shortcuts and run **PandaPay Import Demo History**. Its actions are **Load 100 Demo Messages (Prototype)** → **Import Message Batch (Prototype)**. The second action's Messages JSON parameter is bound to the first action's actual output variable.
4. Dismiss the result dialog, then reopen PandaPay. It parses captured inputs on resume and shows native counts, the last batch report and financial observations with original timestamps.
5. Run the Shortcut again to verify zero added captures. The separately saved **PANDAPAY History Probe** remains an unfiltered Apple Find Message → Count workflow and currently returns 0.

## Implementation and verification

- Native batch intake validates a JSON array of at most 200 records, requires sender and parseable original ISO dates, applies the synthetic marker and native security gates, and reuses the same durable capture function as the single-message App Intent. Invalid or sensitive individual messages are counted without stopping the remaining batch.
- Fractional seconds are preserved in original timestamps and replay identities.
- The Dart adapter now calls **the same `classifySmsTriage` used by Android before the canonical financial parser**. The mixed corpus caught why this matters: calling the parser alone can produce typed ignore observations for promotional content. Those are now excluded before financial observation counting.
- The simulator screen includes the seeded input count, a dated demo inbox, native capture count, last batch outcome and financial results. These are prototype observations; no production transactions are created.
- Native App Intents and capture storage remain guarded by `DEBUG && targetEnvironment(simulator)`. The queue is disposable synthetic JSON, not a production encrypted intake design. Real device support requires a separate storage/configuration step.
- **7 focused tests passed**, covering the original handoff envelope checks, all 100 historical dates, Android triage/parser outcomes for the mixed corpus, and equal-text/different-date events.
- Targeted Dart analysis: **No issues found**. ARM64 simulator Xcode build: **BUILD SUCCEEDED**. Actual Shortcuts execution and the final app results screen were verified through the simulator UI.

Machine-readable observed results are in [verification.json](../artifacts/ios-history-prototype-2026-10-26/verification.json). Source build/reproduction commands remain in the [earlier prototype report](ios-shortcuts-prototype-results-2026-10-26.md). Before a direct Xcode build after restoring the production lockfiles, run `PANDAPAY_SIMULATOR=1 pod install` from `app/ios` to regenerate the existing simulator-only pod configuration. Exclude its incidental lockfile changes from the source diff.

To regenerate and verify the corpus, from `app`:

```sh
dart run tool/generate_ios_prototype_history.dart
flutter test test/data/ios_import_prototype_test.dart test/data/ios_import_prototype_history_test.dart
dart analyze lib/data/ios_import_prototype.dart lib/data/ios_import_prototype_fixtures.dart lib/main_ios_import_prototype.dart test/data/ios_import_prototype_history_test.dart tool/generate_ios_prototype_history.dart
```

## Remaining acquisition work

On a physical iPhone, first prove that Apple Find Message returns known old bank messages and their full body, sender and original receive date. Then connect those real outputs to the common batch adapter, add a user-selected date range and bounded/resumable windows, and test repeated history recovery. This prototype deliberately does not present its fixture source as that completed Apple Messages integration.
