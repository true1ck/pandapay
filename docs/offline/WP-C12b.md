# WP-C12b: offline-aware errors, one "saved" message, cold-start caps

Branch `offline/c12b`. Additive: an online, healthy user sees the same copy and timings (unknown reachability is online).

| Area | Change |
|---|---|
| `ErrorState` | Constructor unchanged; new optional `error` and `hasCachedData`. Offline (the error `isOfflineLike`, `KnownConnectivity.knownOffline`, or the server known unreachable) shows a cloud-off icon, "Can't reach PandaPay", and "Showing what's saved on this phone." (with cached data) or "Connect to the internet and try again." Works without a `ProviderScope`. Existing call sites do not pass `error`, so they go offline-aware only through known connectivity/reachability. |
| `userFacingErrorMessage` | `ClientException`/`TimeoutException`/`SocketException` (and any unknown error while known offline) give `offlineErrorMessage` ("You're offline. Try again when you're connected."). Generic fallback is now "Something went wrong. Try again." Hand-written messages are untouched. |
| Saved offline copy | `app/design/saved_offline.dart`: `savedOfflineCopy` + `showSavedOfflineSnack(context, {what})`. Migrated: edit transaction, edit card, manual overrides, transaction detail (note, split caption), quick add, notification settings, shared-expenses runtime (`sharedSavedOfflineCopy` is an alias). |
| Background policy | `AuthenticatedHttpTimeoutPolicy.background` (6 s header / 8 s overall), opted in only through `runBackground(...)` (a zone value read by the default `timeoutFor`). Used by: recovery-email reminder status, settings pull on sign-in/cold start, push registration `start()`. The first two also skip when `ServerReachability.shouldSkipBackgroundReads`. Reconnect and resume paths are not skipped. User-initiated writes keep 15/30 s. |
| Analytics | `flush` POST has an 8 s timeout (events are restored on failure). |
| Crash reporter | Queue is flushed (`crashReporter.start()`) on offline to online, from `connectivityBootstrapProvider`. |
| `rive` | Removed from `pubspec.yaml` (zero imports in app/lib, app/test, packages/). |

## Not done / notes
- SMS v2 lifecycle left alone (C9 already bounds its calls); `syncLifecycleProvider` (sync engine) untouched on purpose.
- Call sites of `ErrorState` were not mass-edited to pass `error`.
- Pre-existing: `lib/features/settings/merchant_future_rules_screen.dart` is not valid UTF-8, which fails three grep-guard tests (`card_snapshot_sites`, `local_sms_rig_release_gate` x2, `recommendation_confidence_screens`) on this branch regardless of this package.

Tests: `app/test/offline/c12b_*_test.dart`.
