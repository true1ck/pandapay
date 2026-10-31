# PandaPay real-world performance and reliability test matrix

Status: execution in progress. Branch `codex/ios-shortcuts-prototype`. This matrix complements `mobile-performance-stabilization-plan-2026-10-31.md`. A passing unit test is not evidence of a frame-time target; record both correctness and profile-device metrics.

## Measurement contract

Use an unchanged profile APK, account/data snapshot, network setting and device for before/after runs. Preserve app data. Record device/model/Android version/refresh rate, APK commit and build number, account row counts, captured/pending SMS counts, connectivity, battery/thermal state, and each trial's timestamp. Measure at least 10 process-cold launches (`am force-stop`, then `am start -W`), 10 warm resumes, and 5-minute scroll sessions per representative tier. Separate Android first displayed frame, Flutter first frame, PandaMark splash resolution, Home first frame and first usable interaction. Log p50/p95/max; for frames record UI/raster build durations, missed budgets (>16.67 ms at 60 Hz, >8.33 ms at 120 Hz), p95/p99, and longest stall. Capture CPU, memory, GC, request count/bytes, DB rows/lock wait, and SMS job trigger/duration. Redact tokens, SMS bodies and financial content.

The emulator is a development signal. Release acceptance requires a representative physical Android device with existing user-sized data. A scenario is `PASS` only when its correctness checks pass and its profile metrics meet the agreed device-tier baseline; `UNMEASURED` is not a pass.

## Scenario catalogue

| ID | Real-life setup and action | Correctness assertions | Performance observations | Status |
| --- | --- | --- | --- | --- |
| ST01 | Force-stop signed-in app, reopen online with populated cache, repeat 10x | Correct account and Home; biometric gate respected | icon→first frame, PandaMark duration, usable Home p50/p95 | 3 profile emulator traces; physical pending |
| ST02 | Force-stop then reopen offline | Cached Home/Activity available, no indefinite splash or lost edits | route time, first scroll frames, retries | pending |
| ST03 | Cold start after APK update, without clearing data | Migration and account state correct | first Keystore read, DB open, first Home | one 5.39 s splash outlier observed |
| ST04 | Sign out, sign into another account while Activity/Spending/Wallet/Subscriptions are open | No previous-account rows or report shown even for one frame | route/reload frames | targeted guard in progress |
| ST05 | Biometric enabled, cold start and cancel/retry unlock | No Home data exposed before unlock; retry works | lock appearance and unlock→Home | pending |
| ST06 | Deep link/iOS shortcut while process dead | Intent retained through auth/onboarding gates | callback→destination | pending |
| NV01 | Switch Home, Activity, Spending, Wallet, Insights, You repeatedly with populated data | No stale data, spinner flash or state reset | tap→first content, p95/p99 frames | Activity/Spending reload tests passed; device pending |
| SC01 | Scroll Activity with 3k+ transactions during server refresh | Stable list, filters, selections, no duplicates | frame timing, CPU, DB spans | pending |
| SC02 | Scroll Spending and switch periods while report reloads | Heading/body stable for same query; new period correct | header identity, frames, requests | widget regression passed; device pending |
| SC03 | Scroll Home while SMS upload, sync and Home refresh overlap | Data converges; gestures respond | long frames, job overlap, request fan-out | pending |
| SC04 | Scroll Wallet/Subscriptions during background refresh and archived toggle | No same-query flash; account/query separation | frame timing, spinner transitions | targeted tests passed; full subscription suite unresolved |
| SM01 | First-install inbox with large SMS history and 25-row pages | All eligible rows captured once; checkpoint advances after durable write | time/rows, worker fallback, frames | pending |
| SM02 | Receive SMS in foreground/background and race inbox catch-up | One transaction/review entry, no missed message | delivery latency, duplicate pass count | pending |
| SM03 | Resume offline with 200+ pending uploads, reconnect while scrolling | Durable retry, no duplicate acknowledgments | queue drain, UI frame stalls | pending |
| SM04 | AI review jobs pending/failed; leave app idle 5 minutes | Bounded polls and correct manual override | 4 s/90 s trigger counts, network | pending |
| SY01 | Cross-device changes arrive while Home/Activity visible | Cursor advances after local commit, views converge | full GET count/bytes, SQLite save duration | sync tests passed; device pending |
| SY02 | Interrupt sync at fetch/write/ack and relaunch | Replay safe, no lost/duplicate rows | recovery time and UI stalls | local sync tests passed; device pending |
| DB01 | 3k/10k transaction history; full fetch/save and filter reads | Receipts, edits, deletion and coverage intact | UI-isolate SQL/JSON spans, p99 frames | 3k/200-row host test; device pending |
| DB02 | Versioned SMS/AutoPay repairs after upgrade | Repairs once, user corrections retained, crash-resume safe | repair-on-read count, DB locks | pending |
| BG01 | Five-minute idle, repeated resume/reconnect/account switch | One due job per trigger, timers disposed, no stale-account writes | CPU/memory slope, requests/min, battery proxy | pending |
| ER01 | Slow/502 auth, API, FCM and SMS endpoints | Cache remains usable, bounded retry, errors recover | UI frames and request storm | pending |

## Execution log

31 Oct 2026, profile emulator build 70, ST01 swipe-away reproduction: sent Home and Recents, swiped PandaPay task off-screen, confirmed `pidof` returned no process, then launched via launcher intent. Flutter's first frame was 0.28 s after Dart `main`, onboarding SharedPreferences completed at 8.25 s, first secure access-token read at 11.30 s, splash resolved at 11.39 s, and Home's first frame at 11.77 s. This reproduces the user's long PandaMark wait. These concurrent platform-channel reads were both delayed; the trace does not yet prove whether the Android Keystore, SharedPreferences plugin, emulator scheduling, or UI-isolate contention is the root cause. Repeat on physical device and collect Android main-thread/Flutter CPU traces before changing credential semantics.

31 Oct 2026, profile emulator `sdk_gphone64_x86_64`, dev APK build 69: three process-cold PandaMark resolution samples from Dart main were 5.39, 1.27 and 1.50 s. The first secure-storage read completed at 5.21, 1.26 and 1.23 s respectively; onboarding preferences completed at 1.54, 0.07 and 0.05 s. Android `am start -W` measures first displayed frame only, not usable Home. A later force-stop/reopen on the same emulator resolved PandaMark at 0.65 s from Dart main and reached Home. These runs show variable secure-storage/platform startup; they do not establish physical-device p95 or scrolling performance.

Current focused verification: 85/85 Activity, Spending, sync, SMS intake and edit tests passed for commit `c2479722`. A later combined Activity/Spending/FinancialStore run passed 112/112 against uncommitted follow-up changes. Wallet/Subscriptions reload tests passed individually; three existing Subscriptions suite assertions remain under baseline investigation. Keep those as unresolved until proven pre-existing or fixed.

## Release gate

Do not call the performance work complete until ST01–ST06, NV01, SC01–SC04, SM01–SM04, SY01–SY02, DB01–DB02, BG01 and ER01 have results on a representative physical device or a documented equivalent. Compare the same workload before/after each architectural change. The startup and refresh changes must preserve account isolation, biometric gating, SMS checkpoint durability, sync cursor ordering and user edits.
