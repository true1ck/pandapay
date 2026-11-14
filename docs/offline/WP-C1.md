# WP-C1 — connectivity and reachability core

Branch `offline/c1`. Findings: C-01, C-02 (core only), C-05, L-08, SRV-09 (client half).
Decision D9 (client uses the server-time offset from the `Date` header).

## What changed

| Area | Change | Files |
|---|---|---|
| Seeded connectivity | `isOnlineProvider` now starts from `checkConnectivity()` and follows `onConnectivityChanged`, de-duplicated. `_isKnownOffline()` reads `KnownConnectivity`, updated on every raw value. | `lib/data/connectivity/online_stream.dart`, `known_connectivity.dart`, `lib/app/providers.dart` (`isOnlineProvider`, `_isKnownOffline` only) |
| Early subscription | `connectivityBootstrapProvider` is watched from `PandaPayApp.build`. `_AppShell` and its 500 ms lifecycle timer are untouched. | `lib/data/connectivity/connectivity_bootstrap.dart`, `lib/main.dart` (3 lines) |
| Reachability | `ServerReachability`: cached, never-throwing probe of `GET /app-status`; `serverReachabilityProvider`, `serverReachableProvider`. | `lib/data/connectivity/reachability.dart` |
| `isOfflineLike(error)` | Transient network failure, raw `SocketException`, or any error while the app is known offline. `isTransientNetworkFailure` unchanged. | `lib/data/api_exception.dart` |
| appStatus re-check | On offline -> online, once the probe says the server is reachable, `appStatusProvider` is invalidated. On resume, a failed-open (`null`) status is re-checked. Still fail-open. | `connectivity_bootstrap.dart` |
| Server clock | `Date` header of 2xx API responses -> `ServerClock` offset (clamped +-7 days, noise floor 2 s, ignored if missing/unparsable/cached). `SyncQueue` uses `ServerClock.instance.now()` as the default for its `at` parameters. | `lib/data/server_clock.dart`, `api_request_headers_client.dart`, `lib/data/local/sync_queue.dart` |

No behaviour change in any of the 28 `isOnlineProvider ... == false` call sites; they simply see a value earlier. No banner.

## Design notes and deviations from the plan text

* **Stream shape.** The plan says an `async*` that yields the seed first. A `StreamController` is used instead: it subscribes to the change stream first and fires `checkConnectivity()` in parallel, and the seed is dropped if a change event already arrived (it would be older). Reasons: (1) cancelling an `async*` generator that is parked in `await for` does not release the platform subscription until the next event; (2) a `.timeout()` on the seed leaves a pending 2 s timer in every widget test that reads the provider un-overridden (this broke 14 tests in `edit_transaction_screen_test.dart` when tried); (3) there is no window between "check" and "subscribe". A failing or hanging seed is simply ignored, i.e. behaviour is exactly the old one.
* **Where the appStatus re-check lives.** The plan says "in the same listener area as the display refresh". That listener only exists once the signed-in shell has started, but `appStatusProvider` also gates signed-out users (forced upgrade), so the re-check is in the app-root `connectivityBootstrapProvider`. It is gated by the probe so a reconnect on captive Wi-Fi does not re-fetch and cache another `null`.
* **`KnownConnectivity`** is a tiny static holder so `isOfflineLike` (in `lib/data/`) and the probe can read the radio state without a `Ref`. `_lastKnownOffline` no longer exists; `_isKnownOffline()` delegates to it. Test overrides of `isOnlineProvider` never touched `_lastKnownOffline` and still do not touch `KnownConnectivity`.
* **Server clock.** `SyncQueue(serverClock:)` and `ServerClock(deviceNow:)` are injectable. With no offset `now()` returns the device `DateTime` object itself. The queue `created_at` column is stamped from the same value (as before it was the same `clockMs`). `last_synced_at` (display only) still uses `DateTime.now()`. The offset is sampled at the midpoint of request/response; responses with an `Age` header or a non-2xx status are ignored. Two `ApiRequestHeadersClient` wrappers are stacked in the app (`main.dart` `runWithClient` plus the authenticated client); both observe, which is harmless.

## Using `ServerReachability` (for later packages)

```dart
final reach = ref.read(serverReachabilityProvider);

// Background, non-user-initiated read (home refresh, rules refresh, prefs):
if (reach.shouldSkipBackgroundReads) return cachedValue;   // true only when KNOWN unreachable

// User-initiated read that would otherwise wait 15-30 s on dead Wi-Fi:
if (!await reach.check()) return cachedValue;               // worst case ~1.8 s, never throws

// Widget needing a reactive hint:
final bool? reachable = ref.watch(serverReachableProvider); // null = unknown, treat as online
```

Semantics: radio down => `false` without probing; success cached 20 s, failure 8 s; expires to `null` (unknown), never to a stale answer; concurrent callers share one probe; `invalidate()` on connectivity change and resume (done by the bootstrap provider); a probe landing after `invalidate()` is not cached. "Reachable" means a 200 with a JSON object body (captive-portal HTML, redirects, 5xx all count as unreachable). Unknown must be treated as "go ahead", so un-probed behaviour is unchanged.

Not wired yet (another package will): any read path, `homeDataRefreshProvider`, `SmsV2Runtime._refreshRules`.

## How "online healthy user unaffected" was verified

* Transition tests (`test/data/connectivity/online_stream_test.dart`) use the exact predicate every listener uses (`previous?.valueOrNull == false && next.valueOrNull == true`): seeded online => zero came-online triggers (also when the platform replays the state); seeded offline then first online event => exactly one; a later real cycle => one each; Wi-Fi -> mobile hand-over => none.
* `connectivity_bootstrap_test.dart`: a start that is already online never re-checks appStatus and never probes.
* Existing suites that exercise the provider pass unchanged: `quick_add_offline_test`, `edit_card_screen_test`, `edit_transaction_screen_test`, `offline_banner_test`, `sync_engine_local_test`, `sync_queue_test`, every other test file that mentions `isOnlineProvider`, `widget_test.dart` (pumps `PandaPayApp`), `is_online_provider_test`, `api_request_headers_client_test`, `performance_guards_test`.
* Online with the clock in sync (skew under 2 s): `ServerClock.now()` is `DateTime.now()`; `SyncQueue` clocks are identical to before (`sync_queue_server_clock_test`, `sync_queue_test`).
* Extra network traffic for an online user: none at launch. One `GET /app-status` probe plus one re-fetch of the same endpoint per real offline -> online transition.
* NOT done: `scripts/perf_smoke_android.sh` on a real phone (no device available here). The change adds one provider read at the app root and one stream subscription; no work on the UI isolate beyond that. Run the smoke on a profile build before merge.

## Tests added

`test/data/connectivity/{online_stream,reachability,connectivity_bootstrap}_test.dart`, `test/data/server_clock_test.dart` (includes the `Date` header capture), `test/data/local/sync_queue_server_clock_test.dart`, `isOfflineLike` group in `test/data/api_exception_test.dart`.

## Known gaps / follow-ups

* The offset is in memory only. A cold start offline has offset 0 until the first successful API response; persisting the last offset (SharedPreferences) would fix "phone clock wrong, app killed, edits made offline".
* The +-7 day clamp means a phone off by a year is still about 358 days off client side; the server-side clamp of future clocks (WP-S1) is what protects other devices.
* `isOfflineLike` returns true for any error while the app is known offline, as specified. Do not use it to hide validation errors (`ArgumentError`) behind "saved offline" copy; check those first.
* `shared_providers.dart` still has its own `Connectivity().onConnectivityChanged` listener (not touched).
* Reachability is not probed at launch; today it runs on reconnect only. Call sites will `check()` lazily.
