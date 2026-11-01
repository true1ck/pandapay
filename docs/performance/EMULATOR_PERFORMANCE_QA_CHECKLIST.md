# PandaPay Android performance QA checklist

Status: reusable checklist; emulator execution snapshot recorded 1 November 2026.

This is the operational companion to [`mobile-performance-real-world-test-matrix-2026-10-31.md`](../mobile-performance-real-world-test-matrix-2026-10-31.md). It defines repeatable emulator checks for startup, navigation, scrolling, database/sync work and SMS intake. It is not a release sign-off by itself: a physical-device run with representative data is still required.

## Safety and test identity

- Use a dedicated local-development account and the local dev backend only. The repository README documents the local OTP fixture; never copy production credentials or OTPs into logs or this document.
- Confirm the target serial, package, activity, version code and backend defines before every run.
- Install only with `adb install -r` and a strictly higher version code. Never uninstall, clear data, use `-d`, or downgrade for a performance test.
- Keep the emulator account/data snapshot unchanged between before/after samples. If a test requires a fresh install, use a separate emulator snapshot and label it `fresh-install`; do not reset the populated profile emulator.
- Derive every tap from the current UI hierarchy (`uiautomator dump`). Do not choose coordinates from a screenshot alone.
- Redact access tokens, refresh tokens, email/phone identifiers, SMS bodies, merchant names and transaction amounts from saved logs.

## Required run metadata

Record these fields with every sample:

| Field | Value |
| --- | --- |
| Date/time and timezone |  |
| Git commit and branch |  |
| APK package / version name / version code |  |
| Build mode | profile or release (never debug for smoothness claims) |
| Device serial / model / Android API / refresh rate |  |
| Backend mode and endpoint class | local dev or hosted production; never mix in one comparison |
| Account state | signed-out, onboarding, signed-in, biometric-locked |
| Local data shape | transaction count, card count, captured SMS count, pending queue counts (counts only) |
| Network / battery / thermal state | online/offline, battery %, thermal status |
| Sample number | 1..10 for launch; timestamp for gestures |

## Device and installation preflight

PowerShell (Windows):

```powershell
$adb = 'C:\Users\sujay\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$serial = 'emulator-5554'
$pkg = 'app.pandapay.pandapay.dev2'
$activity = "$pkg/app.pandapay.pandapay.MainActivity"

& $adb devices -l
& $adb -s $serial shell cmd package resolve-activity --brief $pkg
& $adb -s $serial shell dumpsys package $pkg |
  Select-String 'versionCode=|versionName=|firstInstallTime=|lastUpdateTime='
& $adb -s $serial shell pidof $pkg
& $adb -s $serial shell dumpsys thermalservice | Select-String 'Current Thermal Status|Temperature'
```

Expected: one intended emulator serial, the expected PandaPay Dev activity, a version code newer than the installed baseline when an APK update is being tested, and no unexpected process from a different package. A mismatch is a **STOP**, not a reason to uninstall or clear data.

## UI-tree and screenshot evidence

Capture the hierarchy before choosing a control:

```powershell
& $adb -s $serial shell uiautomator dump /sdcard/pandapay_window.xml
& $adb -s $serial pull /sdcard/pandapay_window.xml "$env:TEMP\pandapay_window.xml"
Get-Content "$env:TEMP\pandapay_window.xml" |
  Select-String 'Home|Activity|Spending|Wallet|Insights|You|Create account|I already have an account|PandaPay could not start'
& $adb -s $serial exec-out screencap -p > "$env:TEMP\pandapay_current.png"
```

Save the XML and screenshot with the sample ID. A successful `am start -W` is not proof that the app reached Home; the hierarchy must contain the expected route semantics (for example `Home`, `Quick actions`, or a page-specific heading).

## ST01 — authenticated process-cold launch (10 samples)

Purpose: reproduce the user's “swiped away, reopened, PandaMark stays visible” scenario with a valid signed-in Home state.

1. Confirm the hierarchy currently contains Home and the test account is signed in.
2. Clear only the log buffer, force-stop the package, and launch the resolved activity.
3. Record Android `TotalTime`, host elapsed time, and the first hierarchy sample that contains Home.
4. Repeat 10 times without clearing app data. Wait for the previous launch to become idle before the next force-stop.

```powershell
& $adb -s $serial logcat -c
& $adb -s $serial shell am force-stop $pkg
$t0 = Get-Date
$start = & $adb -s $serial shell am start -W -n $activity 2>&1
$t1 = Get-Date
[pscustomobject]@{
  host_ms = [int](($t1 - $t0).TotalMilliseconds)
  android = (($start | Select-String 'TotalTime|WaitTime|LaunchState').Line -join ' | ')
}
& $adb -s $serial shell uiautomator dump /sdcard/pandapay_window.xml | Out-Null
& $adb -s $serial pull /sdcard/pandapay_window.xml "$env:TEMP\pandapay_st01.xml" | Out-Null
```

Correctness: the same account reaches Home; onboarding, error, sign-in and another-account data must not appear. Biometric-enabled accounts must remain locked until an approved unlock.

Provisional profile-emulator target (ratify against the supported device tier): p95 Android `TotalTime` <= 3,000 ms, max <= 5,000 ms; p95 PandaMark-to-Home <= 2,500 ms; zero indefinite splash/error state. Any sample above 10,000 ms is a failure requiring a trace, not an average to hide.

## ST02 — warm resume (10 samples)

With Home visible, background and foreground the app without force-stopping it. Record the time to an interactive Home control and verify no full-screen splash is shown.

```powershell
& $adb -s $serial shell input keyevent KEYCODE_HOME
Start-Sleep -Milliseconds 1000
$t0 = Get-Date
& $adb -s $serial shell monkey -p $pkg 1 | Out-Null
$t1 = Get-Date
"warm_host_ms=$([int](($t1-$t0).TotalMilliseconds))"
```

Target: p95 to an interactive Home control <= 750 ms; no account switch, duplicate refresh or visible flicker.

## ST03 — first visit and navigation latency

From authenticated Home, use UI-tree bounds to tap each bottom tab and first-visit card: Wallet, Insights, Spending/Trends, Activity/Transactions and You. Record tap-to-page-heading and tap-to-first-interactive-control for the first visit and a repeated visit.

Correctness: page heading, account namespace and data shape are correct; no stale previous-account content, route error, or permanent spinner. Preserve the prior value during an explicit refresh where the query is unchanged.

Target: p95 tap-to-heading <= 1,000 ms, p95 tap-to-first interactive control <= 2,000 ms, and no route with a visible blank/error state caused only by a background refresh.

## SC01 — Home scroll down/up reversal

Use the root `ScrollView` bounds from the hierarchy. Capture a hierarchy before and after each gesture and repeat five times:

```powershell
& $adb -s $serial shell dumpsys gfxinfo $pkg reset
& $adb -s $serial shell input swipe 540 2050 540 550 700
Start-Sleep -Milliseconds 500
& $adb -s $serial shell input swipe 540 550 540 2050 700
Start-Sleep -Milliseconds 500
& $adb -s $serial shell dumpsys gfxinfo $pkg |
  Select-String 'Total frames rendered|Janky frames|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync'
```

Correctness: content bounds move down and then return to the top; gestures do not hang, drop the scroll position, or trigger a duplicate full refresh. Target: no gesture stall >100 ms; at 60 Hz UI/raster p95 <=16.67 ms and p99 <=33 ms, with janky-frame ratio <5%. For a 120 Hz tier use 8.33 ms / 16.67 ms budgets.

## SC02 — Activity and Spending scroll under refresh

Open Activity with at least the representative transaction count, start a refresh or reconnect, and perform the same up/down gesture. Repeat on Spending while changing period/filter once. Record `gfxinfo`, page heading identity and request/job counts.

Correctness: rows remain unique and editable; spending totals do not change unless the query/data changes; headings do not flicker to a blank skeleton; filter and selection state remain valid.

Target: same frame budgets as SC01; no UI-isolate span >100 ms during a gesture; one refresh owner per query and bounded background batches.

## SM01 — SMS inbox catch-up and live listener

Use synthetic, non-sensitive SMS markers only. Run a large-history catch-up on a separate test snapshot, then deliver one live SMS while Home is scrolling.

```powershell
& $adb -s $serial shell am force-stop $pkg
& $adb -s $serial shell am start -W -n $activity | Out-Null
& $adb -s $serial emu sms send +919876543210 'PANDAPAY_PERF_TEST synthetic debit 37'
```

Correctness: durable local capture precedes upload; provider-ID checkpoint advances; duplicate delivery creates one transaction/review row; OTP/security marker is dropped; no raw SMS body is logged.

Target: live capture does not block a 60 Hz gesture; no synchronous fallback processes an unbounded inbox on the UI isolate; catch-up is bounded per pass and resumes after interruption.

## SY01 / DB01 — sync and local database stress

Run with 3k and 10k transaction fixtures on a disposable emulator snapshot. Exercise pull, materialization, offline edits, reconnect and process death during write. Capture row counts, batch size, DB lock wait, JSON parse duration and frame timing.

Correctness: cursor advances only after durable commit; receipts, pending edits, deletions and account isolation survive interruption; replay is idempotent.

Target: foreground pass has a row/time budget and yields between batches; no UI-isolate DB/JSON span >50 ms during interaction; no unbounded outbox drain.

## Evidence collection and failure triage

```powershell
& $adb -s $serial logcat -d -v threadtime -t 2000 > "$env:TEMP\pandapay_perf_logcat.txt"
& $adb -s $serial shell dumpsys meminfo $pkg > "$env:TEMP\pandapay_meminfo.txt"
& $adb -s $serial shell dumpsys gfxinfo $pkg > "$env:TEMP\pandapay_gfxinfo.txt"
& $adb -s $serial shell dumpsys activity exit-info $pkg > "$env:TEMP\pandapay_exit_info.txt"
```

Investigate any failure in this order: (1) verify package/activity/version and account state, (2) classify Android/native versus Dart/UI-isolate versus network/DB timing, (3) capture a profile trace while reproducing, (4) compare the unchanged baseline on the same device/data, and (5) only then change code. A partial build, HTTP health response, or first-frame marker without a usable Home hierarchy is not a pass.

## Execution snapshot — 1 November 2026 emulator

This is diagnostic evidence, not release acceptance. Emulator `emulator-5554` ran Dev package `app.pandapay.pandapay.dev2`, profile build `8112`, against the healthy local API/auth services on host ports 4001/3210. The existing data directory and first-install time were preserved with `adb install -r`.

- Three authenticated force-stop launches reached Home in Android `TotalTime` 4,704 ms, 5,090 ms and 5,099 ms; Home was confirmed by the UI hierarchy. This reproduces a multi-second cold-start delay even after authentication.
- The same samples logged repeated skipped-frame bursts (up to 104 frames) and Flutter frame telemetry with raster p95 around 570–596 ms. `gfxinfo` showed 100% janky frames in a short cold-start sample. This is a severe emulator renderer/jank signal and requires a profile trace; it is not evidence to blame images alone.
- First authenticated Insights navigation rendered its heading/cards; first Spending navigation rendered the report and categories; Activity rendered 3 transactions and accepted the tested scroll gesture. Home up/down scrolling moved the `ScrollView` content and returned to the top. No crash, ANR or sign-out occurred.
- The first APK attempt (release Dev build 8111) correctly stopped on the app's “compiled as dev; use production build” guard. It was replaced in-place with profile build 8112; no data reset occurred.

These observations should be repeated after each performance change using the same serial, account/data shape and commands above. Do not mark ST01/SC01 complete from this snapshot alone; the physical-device and 10-sample gates remain open.

## Post-change verification — 1 November 2026

The warm-shell/session-presence change was built as Dev profile APK version code **8114** and installed with `adb install -r` over 8113. The emulator package remained `app.pandapay.pandapay.dev2`; `firstInstallTime` stayed `2026-11-01 00:21:28`, confirming that app data was preserved.

- Four process-cold launches on the changed source logged `Home first frame` at approximately 53 ms, 97 ms, 130 ms and 408 ms from Dart start when the emulator was not being rebooted. One noisy sample logged 2,980 ms; Android host/renderer timing is variable and must not be hidden by an average.
- The UI hierarchy on the final 8114 launch contained the authenticated Home controls and did not contain `Create account` or `I already have an account`. The final screenshot showed the existing ₹324 transaction summary and wallet recommendations; no onboarding or error screen appeared.
- On 8113 (same source except a null-aware lint cleanup), UI-tree-derived checks moved Home's `Spending amount` bounds from `[0,1523][1080,2006]` to `[0,11][1080,494]` and back to `[0,1261][1080,1744]`. Insights, Spending, Activity, Wallet and You all opened on first visit; Activity displayed the existing three rows.
- The emulator renderer remains a separate open issue: a reset `gfxinfo` sample after Home navigation and two scrolls reported 42/42 janky frames, 95th percentile 750 ms, 99th percentile 4,950 ms and 41 slow issue-draw commands. This is consistent with the earlier OpenGL/EGL-emulator evidence and is not a clean physical-device smoothness result.

The warm-shell change removes the secure-storage read from the visible splash gate; it does not claim that the emulator's GPU path is healthy. Physical-device profiling and the 10-sample acceptance gates remain required before release approval.
