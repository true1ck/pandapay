# PandaPay performance rulebook

Why this exists: the app was optimised on 18 Oct and 1 Nov 2026 and the lag came back
anyway. Both fixes lived in prose handoff documents; nothing failed when a later change
broke them. This file is short on purpose, every rule is backed by a measured incident,
and the rules that can be checked by a machine **are** checked
(`app/test/performance_guards_test.dart`, `scripts/perf_smoke_android.sh`).

If you are an AI agent or a new developer: read sections 1 to 3 before touching SMS,
sync, the local database, providers or startup. A change that breaks a rule needs the
owner's explicit sign-off in the PR, not a silent `perf-ok`.

## 0. What happened (so the rules make sense)

| Date | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 18 Oct | ANR, 10 s input timeout | SMS inbox query on the Android main thread | native worker + dedicated Dart capture isolate |
| 1 Nov | slow cold start, scroll stalls | broad rework, `FinancialReadWorker` added | partial; handoff doc written |
| 5 Nov | (silent) | SMS v2 replaced the legacy pipeline (`0364192b`). The dedicated capture isolate was deleted and v2 ran the same work **synchronously on the UI isolate** | nothing noticed it |
| 7 Nov | UI thread at **100 % CPU for 30+ s** after every launch on a Motorola Edge 50 Fusion | three quadratic hotspots, found by a Dart CPU profile (see 5) | commits `59f57285`, `d9629839` and the follow-up |

The 7 Nov hotspots, so you can recognise the shape of the mistake:

1. Needs-review badge built the whole review list, one SQLite query per item
   (`reviewItemsProvider`, `FactStore.forSource` scanning the whole fact table).
2. `SyncPull` called `categoryDecisions()` (decodes the entire ledger) once per incoming
   entry, and `forEvent` once per event.
3. Rebuilding `SmsV2Runtime` (it watches categories, catalogue and app version, so it is
   rebuilt several times at startup) re-parsed, re-validated, re-hashed and re-verified the
   same SMS rule bundle each time.

## 1. The rules

**R1. The UI isolate does only small, bounded work.** Anything that is O(history) or
O(inbox), SQLite or JSON or crypto or regex heavy, runs in an isolate (`compute`,
`Isolate.run`, or a worker like `FinancialReadWorker`) or in explicit, measured,
time-sliced chunks. When you replace a subsystem, port its threading guarantees first
(R9). Enforced by review and by `perf_smoke_android.sh`.

**R2. `async` is not a thread.** `await`, `Future`, and `Future.delayed(Duration.zero)`
only let other events interleave; the code between awaits still blocks frames. A
`Duration.zero` yield in data/SMS code needs a `perf-ok: <why the chunk is bounded>`
comment. Enforced: `performance_guards_test.dart`.

**R3. Per-message and per-row code allocates nothing expensive.** No `RegExp(...)` in
per-message code (use `cachedRegExp` from `lib/data/cached_regexp.dart`, or a top-level
`final`). No hashing, schema validation, `jsonDecode` or signature checks of data that has
not changed: cache the decoded immutable object (facts are immutable, so
`FactStore.all()` reuses decoded facts; `BundleStore` reuses a verified bundle per
database). Enforced for the hot files: `performance_guards_test.dart`.

**R4. No O(N^2).** Never read the whole table/ledger/history inside a loop over rows.
Read once and group in Dart, or use `IN (...)` per chunk (max 400 ids). Name the loop
bound in a comment when it is not obvious. `categoryDecisions()` with no `eventIds` is
"whole ledger". Enforced for sync pull / history recheck: `performance_guards_test.dart`.

**R5. Index discipline.** There is no index on JSON paths. `json_extract(payload, ...)`
in a `WHERE` is a full scan: run it once per chunk, never once per row. For an equality
lookup that also has an `ORDER BY`, pin the index with `INDEXED BY` (SQLite can choose
an index that satisfies the ordering and scan the whole table; `INDEXED BY` turns that
into an error). Check every new query with `EXPLAIN QUERY PLAN`: `SEARCH ... USING
INDEX`, never `SCAN` on a growing table. Enforced for the two known cases:
`performance_guards_test.dart`.

**R6. Providers.**
- A cheap UI value (badge, count) must not depend on building an expensive list. Give it
  its own `SELECT COUNT(*)` or a cached value.
- Watch the narrowest revision. A provider that rebuilds on `observations`/`transactions`
  must be O(changed) or cached; this app has 6+ providers on each of those.
- A long-lived object (like `SmsV2Runtime`) that watches providers which resolve once at
  startup is rebuilt several times. Expensive immutable state it owns must survive
  rebuilds (key a shared cache on content hash and database).

**R7. Startup budget.** Reference phone: Motorola Edge 50 Fusion, profile build, signed
in with a real history. After a cold start the UI thread must not be saturated for more
than 16 s in a row, and must be at most 15 % busy once the app has been up 30 s. The
target is lower; the gate is what CI-style checks can hold reliably. Home paints from
local data before any network refresh.

**R8. Scrolling budget.** Median UI p95 <= 8 ms while swiping Home/Insights/Activity on
a profile build (the app logs `PandaPay frames ... ui_p95_us=`).

**R9. Rewrites carry the performance contract.** A PR that replaces or deletes a
subsystem must list, in its description, the threading, chunking, indexing and budget
guarantees of the old one, and show where each now lives. The 5 Nov SMS v2 switch removed
the capture isolate without saying so. Do not delete the old code path until the parity
list is checked.

**R10. Measure on a real phone, on a profile build, before and after.** Opinions about
performance are not evidence. Debug builds and emulators are not evidence.

## 2. How to check your change (5 minutes)

1. Unit guards (runs everywhere, also in CI):
   `flutter test test/performance_guards_test.dart`
2. On a phone (profile or release build, signed in, USB debugging):
   `scripts/perf_smoke_android.sh -s <serial>`
   It cold-starts the app, samples the main thread CPU for 44 s, scrolls Home, and exits
   non-zero when R7/R8 are broken.
3. If it fails, find out why with a CPU profile (section 5). Do not tune thresholds to
   make it pass.

Build a test APK that passes the forced-upgrade gate (dev builds report `1.0.17-dev`,
which the gate currently reads as `1.0.0`; see section 6):

```
flutter build apk --profile --flavor dev --build-name 1.1.0 --build-number <higher than installed> \
  --target-platform android-arm64 \
  --dart-define=PANDAPAY_ENV=dev_hosted \
  --dart-define=PANDAPAY_API_BASE_URL=https://api.pandapath.site \
  --dart-define=PANDAPAY_AUTH_BASE_URL=https://auth.pandapath.site \
  --dart-define=PANDAPAY_LEGAL_BASE_URL=https://api.pandapath.site/legal/
adb install -r -d build/app/outputs/flutter-apk/app-dev-profile.apk
```

Build from the branch you ship (`latest-dev`), not from a feature branch with an older
`pubspec.yaml` version: it will show "Update required" and every number you take is
meaningless.

## 3. Review checklist (copy into the PR)

- [ ] Does anything new run at startup, on resume, or on a revision bump? What is its cost
      at 5,000 transactions / 20,000 SMS, and is it on the UI isolate?
- [ ] Any loop with a query, a `categoryDecisions()`, `list()`, `jsonDecode` or a regex
      construction inside it?
- [ ] New SQL: `EXPLAIN QUERY PLAN` checked, index named, no per-row `json_extract`?
- [ ] New provider: does it make a cheap value depend on an expensive one? Does a
      resolve-once dependency make its object rebuild at startup?
- [ ] Replacing a subsystem: parity list for threading and budgets (R9)?
- [ ] `performance_guards_test.dart` and, for startup-affecting changes,
      `perf_smoke_android.sh` run and attached.

## 4. Where heavy work still runs on the UI isolate (known debt)

Measured on 7 Nov after the fixes; the UI thread now settles in about 20-25 s instead of
never. This is the next work, in order of cost:

1. `SyncPull._rebuildDisplay` + `ProjectionWriter.write` (ledger projection after a pull).
2. SMS v2 capture and pipeline (`SmsV2Runtime.capture`, 200-message chunks, synchronous
   SQLCipher on the UI isolate). Move to a dedicated isolate with its own connection, as
   the legacy pipeline did (`docs/sms-capture-and-sync-architecture.md`).
3. Ledger read model rebuilds on every `observations`/`transactions`/`cards` bump
   (`smsV2LedgerReadModelProvider`): all entries, events and transactions. Make it
   incremental or compute it in the read worker.
4. `HistoryCategoryRecheck` over the whole history on first sync after a rule update
   (now one scan per chunk, still on the UI isolate).
5. Rule-bundle and catalogue parse/validate (cached per database/hash; first load still
   on the UI isolate).

## 5. Finding the cause: CPU profile over the VM service

A profile build prints `The Dart VM service is listening on http://127.0.0.1:<port>/<token>/`.

```
adb logcat -d | grep "VM service is listening"
adb forward tcp:<port> tcp:<port>
```

Then over the websocket `ws://127.0.0.1:<port>/<token>/ws`: `setFlag name=profiler
value=true`, wait 15-25 s through the slow window, call `getCpuSamples` on the `main`
isolate, and aggregate the stacks by inclusive frame. Look for one frame that owns most
samples. `sqlite3_step` at the top means a query is scanning; the frames below it name
the caller. (The CPU counters need no profile at all: `/proc/<pid>/task/<pid>/stat`
fields 14+15 on the main thread, which is what the smoke script reads.)

## 6. Related defects found while writing this

- The forced-upgrade gate parses the version with `int.tryParse`, so the dev flavor's
  `1.0.17-dev` becomes `1.0.0` and every dev build shows "Update required" once the server
  minimum is 1.0.17. Strip the suffix before comparing.
