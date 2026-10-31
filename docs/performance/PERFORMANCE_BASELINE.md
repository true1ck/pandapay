# Profile baseline — 31 October 2026

Device: Android 15/API 35 `sdk_gphone64_x86_64` emulator, Flutter 3.44.8 profile dev APK. Existing app data preserved. No physical device connected. Build number 70 includes a Home first-frame marker; measurements cannot be generalized to lower-end phones or release builds.

| Scenario | First Flutter frame from Dart main | PandaMark route resolved | Home first frame | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Recents task swipe, process confirmed absent, launcher intent | 0.28 s | 11.39 s | 11.77 s | Reproduces severe startup wait; onboarding preference returned at 8.25 s, first secure-storage token read at 11.30 s. |
| Earlier process-cold `am force-stop` profile samples, build 69 | not captured | 5.39 / 1.27 / 1.50 s | not captured | Different termination path and earlier marker set; do not combine into one percentile. |
| Later process-cold `am force-stop`, build 69 | not captured | 0.65 s | confirmed via UI hierarchy, timestamp absent | Variable timing; does not negate the long swipe-away run. |
| Three more Recents-removal plus verified process-cold runs, build 70 | captured in log | 1.17 / 1.23 / 1.74 s first secure read | 1.33 / 1.32 / 1.82 s | One run logged 67 skipped Android frames. Swipe removal alone sometimes retained the process, so force-stop was used for guaranteed cold trials. |
| Additional verified force-stop, build 70 | 0.18 s from Dart main | 1.56 s | 1.68 s from Dart main | Android `am start -W` TotalTime was 9.66 s. A large delay happened before Dart main in this run; source remains unproven. |

First Flutter frame is not usable Home. Android `am start -W` reports displayed activity, which can precede Home. The 11.77 s sample does not yet isolate whether platform storage, Android main-thread scheduling, emulator-wide contention, or Flutter UI-isolate work caused the delayed plugin responses. Both SharedPreferences and secure storage were delayed in that run. Another run showed a substantial delay before Dart main. These are separate stages and require an Android startup trace plus a representative physical-device profile before assigning root cause.

1 November 2026: captured a 15-second Android Perfetto trace during a force-stop launch of profile APK build 72 (`docs/performance/pandapay_startup.pftrace`, local artifact, 31 MB). The same run reported `am start -W` TotalTime 3.43 s. The trace is evidence for follow-up analysis, not a numeric frame result yet; open it in Perfetto to inspect Android main-thread, Flutter engine threads, binder calls and process scheduling around the first frame.

UI/raster p95/p99, janky-frame percentage, CPU, memory, navigation and scroll metrics: **unmeasured**. The regression tests in `mobile-performance-real-world-test-matrix-2026-10-31.md` are correctness tests and must not be reported as performance results.
