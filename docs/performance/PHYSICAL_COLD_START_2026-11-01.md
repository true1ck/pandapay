# Physical cold-start evidence — 1 November 2026

Target: Motorola edge 50 fusion, Android 16, serial `ZA222MS4SF`.

Installed package was inspected without uninstalling or clearing data:

- package: `app.pandapay.pandapay.dev2`
- version: `1.0.20-dev` / versionCode `8109`
- first install: `2026-10-31 01:25:54`
- last update: `2026-11-01 10:59:06`
- process was force-stopped only; no `pm clear`, uninstall, or downgrade was used

## Cold launch

`am start -W` after `am force-stop` reported `LaunchState: COLD` and `TotalTime: 1545 ms`.
The app was visibly signed in and Home was visible after the capture window. Flutter log markers in the same run were:

| Marker | Relative time |
| --- | ---: |
| Dart main | 0 ms |
| first Flutter frame | 94 ms |
| token/preferences ready | 419 ms |
| splash resolved | 420–425 ms |
| Home frame / Home first frame | 501–502 ms |

Artifacts from this run are under `docs/performance/android-perf-20261101/`:

- `physical-cold-logcat.txt`
- `physical-cold-after-12s.png`
- `physical-cold-visible.png`
- `physical-cold-gfxinfo.txt`

## What the run proves

This installed build did not reproduce a 7–10 second splash hold: the authenticated Home route resolved in about 0.5 seconds after Dart startup. The native activity launch itself was 1.545 seconds. Therefore the reported 7–10 second case is conditional and still needs a run with the exact affected build/account/backend state.

The run did expose two separate performance risks:

1. Android reported `Skipped 35 frames` during the initial launch.
2. Flutter frame markers showed raster spikes of approximately 34.5 ms, 28.8 ms, 22.4 ms, and 16.8 ms in the first frames, while Dart build times stayed mostly below 4 ms. This points more toward first-frame raster/engine/plugin work than a Dart widget-build loop.

After Home was already visible, background work logged a refresh timeout, 401 session-invalid SMS sync, and FCM registration failures. Those failures are not the cause of the measured Home route delay in this run, but they can create post-launch retries and UI invalidations on a stale/expired session.

## Caveat

The installed package is the `dev2` flavor. The source default for that flavor is local/emulator endpoints unless the APK was built with production `--dart-define` values. The exact backend baked into this already-installed APK was not inferable from `dumpsys package`; production-vs-local must be recorded from the build command or a fresh, version-preserving artifact before using this run as production evidence.
