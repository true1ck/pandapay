# Release builds: obfuscation and symbolication

Every release build of the app is obfuscated. Dart class, method and field names in the shipped binary are replaced with short meaningless names, and a separate symbol file keeps the mapping. Without the symbol file for that exact build, a crash trace from a phone cannot be read.

## What builds are obfuscated

| Command | Where | Flags |
|---|---|---|
| `scripts/build_app.sh <env> [apk\|appbundle]` | Mac and Linux, and the Fastlane lanes | Adds `--obfuscate --split-debug-info=build/debug-info` unless the build is `--debug` or `--profile` (Flutter refuses obfuscation there). Override the folder with `PANDAPAY_DEBUG_INFO_DIR`. |
| `scripts/build_app.ps1` | Windows | Always adds both flags. |
| `app/android/fastlane/Fastfile`, lanes `internal`, `closed`, `closed_draft`, `production_draft` | Play uploads | Passes both flags explicitly and stops if `build/debug-info` has no `app.*.symbols` file. |
| `.github/workflows/build-and-test.yml`, "Build prod bundle" | CI | Both flags, then uploads `app/build/debug-info/` as the artifact `app-debug-info-<commit sha>` (90 days). |
| iOS release | Xcode machine | No script builds the iOS release today. Use the command below. |

iOS release build (no flavors on iOS):

```bash
cd app
flutter build ipa --release \
  --obfuscate --split-debug-info=build/debug-info \
  --dart-define=PANDAPAY_ENV=prod \
  --dart-define=PANDAPAY_API_BASE_URL=https://api.pandapath.site \
  --dart-define=PANDAPAY_AUTH_BASE_URL=https://auth.pandapath.site \
  --dart-define=PANDAPAY_LEGAL_BASE_URL=https://api.pandapath.site/legal/
```

Archive the folder with the build (see below). If an iOS build is ever added to CI or Codemagic, give it the same two flags and the same artifact upload.

## Keep the symbol files

Each build writes one `app.<platform>-<arch>.symbols` file per architecture into `app/build/debug-info/`, for example `app.android-arm64.symbols`, `app.android-arm.symbols`, `app.android-x64.symbols` and `app.ios-arm64.symbols`. Each file is tied to one build (its build id). A later build, even from the same commit, will not match.

- Store the folder with the build number: the CI artifact for CI builds, a folder named after the build number for local Fastlane builds. Keep it as long as that build can still be installed.
- The files contain code names only, no user data and no secrets. They are still not published; keep them in private storage, because they undo the obfuscation.
- `build/` is gitignored. Do not commit the symbols.

## Read a crash trace

An obfuscated release trace looks like this:

```
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1234, tid: 1234, name: 1.ui
build_id: '4f3a...'
isolate_dso_base: 7b3c000000, vm_dso_base: 7b3c000000
#00 abs 0000007b3c5a1234 virt 00000000005a1234 _kDartIsolateSnapshotInstructions+0x2c1f4
```

1. Find the `build_id` line and pick the release whose `.symbols` file has the same build id (`grep` the id in the files, or use the artifact for that build number).
2. Save the trace to a text file and run:

   ```bash
   flutter symbolize -i trace.txt -d app/build/debug-info/app.android-arm64.symbols
   ```

   Use the `.symbols` file for the phone's architecture (arm64 for almost every phone).
3. The output is the normal Dart trace with file names and line numbers.

For native (C/C++ or NDK) frames from Play Console, use the `symbolize-android-stacktrace` skill. Android builds keep native debug symbols in `app/build/app/intermediates/merged_native_libs/` and in the AAB.

## Known gap: in-app error reports lose code locations

`app/lib/app/crash_reporter.dart` (`parseFrames`) keeps only trace lines shaped like `#0 function (package:pandapay/file.dart:12:3)`. An obfuscated release trace has the `#00 abs ... virt ...` shape, so a release report sent to GlitchTip will contain the error class name and app version but no frames. Reports from obfuscated builds therefore cannot be symbolicated from GlitchTip alone.

This is a change in `app/lib`, which this task did not touch. A follow-up should either (a) also send the raw `build_id` line and the `abs`/`virt` offset lines (no user data in them) so they can be symbolicated offline with the matching `.symbols` file, or (b) accept that release reports carry class and version only and rely on Play Console and App Store crash reports for locations. Until then, treat the symbol files as required for Play and App Store crash traces and optional for GlitchTip.

## Verify an obfuscated build

```bash
cd app
flutter build apk --release --flavor dev --obfuscate --split-debug-info=/tmp/pandapay-symbols
ls /tmp/pandapay-symbols        # one app.android-*.symbols per architecture
```

The dev flavor is only for this check. Never ship it. Then install the APK on an emulator and confirm the app opens before trusting the flags on a signed release.
