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
  --dart-define=PANDAPAY_API_BASE_URL=https://api.pandapath.live \
  --dart-define=PANDAPAY_AUTH_BASE_URL=https://auth.pandapath.live \
  --dart-define=PANDAPAY_LEGAL_BASE_URL=https://api.pandapath.live/legal/
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
pid: 4242, tid: 4243, name 1.ui
os: android arch: arm64 comp: yes sim: no
build_id: '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
isolate_dso_base: 7b3c400000, vm_dso_base: 7b3c400000
isolate_instructions: 7b3c410000, vm_instructions: 7b3c404000
    #00 abs 0000007b3c5a1234 virt 00000000001a1234 _kDartIsolateSnapshotInstructions+0x191234
```

1. Pick the `.symbols` file. The build number tells you which build (CI artifact `app-debug-info-<commit sha>`, or the local folder named after the build number). The `arch:` value tells you which file: `arm64` means `app.android-arm64.symbols` on Android and `app.ios-arm64.symbols` on iOS.
2. Check that the file belongs to this exact build: its build id must equal the trace's `build_id`.

   ```bash
   file app.android-arm64.symbols    # ELF: prints BuildID[md5/uuid]=0f1e2d3c...
   dwarfdump --uuid app.ios-arm64.symbols   # Mach-O: prints UUID 0F1E2D3C-4B5A-...; same hex, upper case with dashes
   ```

   The id is binary inside the file, so `grep` does not find it. If no file matches, the trace cannot be read; a build from the same commit does not help.
3. Save the trace to `trace.txt` and run:

   ```bash
   flutter symbolize -i trace.txt -d app.android-arm64.symbols
   ```

4. The output is the normal Dart trace with file names and line numbers. Lines it cannot resolve are printed unchanged, which usually means the wrong `.symbols` file.

For native (C/C++ or NDK) frames from Play Console, use the `symbolize-android-stacktrace` skill. Android builds keep native debug symbols in `app/build/app/intermediates/merged_native_libs/` and in the AAB.

## In-app error reports (GlitchTip) from obfuscated builds

`app/lib/app/crash_reporter.dart` sends one report per error to the `pandapay-app` project. For an obfuscated build it reads the trace with `app/lib/app/obfuscated_trace.dart` and sends only:

| Field in the event | Example | What it is |
|---|---|---|
| `release` | `pandapay@1.0.16+105` | App version and build number: which build's symbol folder to use |
| tag `build_id` | `0f1e2d3c4b5a69788796a5b4c3d2e1f0` | The build id, to check the `.symbols` file (step 2 above) |
| exception `type` | `FormatException` (or an obfuscated class name) | Error class only, never the message |
| exception `value` | `_kDartIsolateSnapshotInstructions+0x191234` | The newest frame's offset |
| stack frames | `function` `_kDartIsolateSnapshotInstructions+0x191234`, `instruction_addr` `0x1a1234` | Per frame: offset into the Dart instructions and binary-relative address |
| extra `obfuscated_trace` | the text below | The same frames as a trace `flutter symbolize` reads |

Never sent: the error message, the process and thread ids, the thread name, absolute addresses and load bases (they show the phone's memory layout), library paths (they contain the install path), and any frame text that is not a hex offset or one of the two `_kDart...SnapshotInstructions` names. Absolute addresses are written as zeros in `obfuscated_trace`; `flutter symbolize` does not need them.

`obfuscated_trace` looks like this:

```
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
os: android arch: arm64 comp: yes sim: no
build_id: '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
    #00 abs 0000000000000000 virt 00000000001a1234 _kDartIsolateSnapshotInstructions+0x191234
    #01 abs 0000000000000000 virt 0000000000100000 <unknown>
```

To read a GlitchTip report:

1. Open GlitchTip (`http://<tailscale-ip>:8000`, see `deploy/monitoring/README.md`), project `pandapay-app`, and the issue. Note the `release` and the `build_id` tag.
2. Get `obfuscated_trace` into a file with its line breaks. Either copy it from the event's additional data into `trace.txt`, or save the event's JSON as `event.json` and run:

   ```bash
   jq -r '(.extra // .context).obfuscated_trace' event.json > trace.txt
   ```

   If neither is available, write `trace.txt` by hand from the event: the header line, `build_id: '<build_id tag>'`, then one line per frame, newest first, in the form `    #00 abs 0000000000000000 <function>` (for example `    #00 abs 0000000000000000 _kDartIsolateSnapshotInstructions+0x191234`).
3. Pick and check the `.symbols` file for that build number and `arch` (steps 1 and 2 of "Read a crash trace").
4. Run `flutter symbolize -i trace.txt -d <that .symbols file>`.

One build's offsets mean nothing in another build, so the report's fingerprint includes the build id: the same crash in two builds shows as two GlitchTip issues.

Checked on 6 Nov 2026: a real trace from `dart compile exe` with `--obfuscate --dwarf-stack-traces`, passed through `ObfuscatedTrace` and back out as `obfuscated_trace`, gave the same `flutter symbolize` output (file:line for every frame) as the original trace. Not yet checked: a report from a real phone through GlitchTip, and which GlitchTip page shows `extra` best (step 2).

## Verify an obfuscated build

```bash
cd app
flutter build apk --release --flavor dev --obfuscate --split-debug-info=/tmp/pandapay-symbols
ls /tmp/pandapay-symbols        # one app.android-*.symbols per architecture
```

The dev flavor is only for this check. Never ship it. Then install the APK on an emulator and confirm the app opens before trusting the flags on a signed release.
