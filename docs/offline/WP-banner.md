# WP-banner (WP-C13-lite): app-wide sync status strip

Branch `offline/banner`. Plan: `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`
(K5, K6, D2, U-01, U-02, WP-C13). Owner decision D2: build a **new** banner that
is small, sits at the top and is visible across the whole app. This reverses the
2026-10-18 removal of Home's own banner (commit `37f7d9c7`) only in the sense of
adding a different thing: HomeScreen itself still renders no connectivity text.

## What the person sees

A slim strip (status-bar inset plus one 24 dp line, 12 sp, single line,
ellipsised) above every route, including sign-in and onboarding. Healthy state:
nothing, zero height.

States, highest priority first (copy is exact):

| # | State | Copy | Shown when |
|---|---|---|---|
| 1 | offline | `Offline · showing saved data` (+ ` · N waiting to sync`) | `isOnlineProvider` is false |
| 2 | unreachable | `Can't reach PandaPay · showing saved data` (+ ` · N waiting to sync`) | radio up, and 2 consecutive probes of `GET /app-status` failed |
| 3 | syncing | `Syncing N changes…` (`Syncing 1 change…`) | online, reachable, queue non-empty for more than 2 s |
| 4 | needs attention | `N changes need attention` (`1 change needs attention`) | parked/blocked rows plus Split's `needsAttentionCountProvider` > 0; amber tone |
| 5 | hidden | (none) | everything else |

Signed out (namespace `signed-out`): only states 1 and 2, never a count.
Unknown connectivity (stream not emitted yet) counts as online.
The exact legacy phrase "You're offline" is not used anywhere in the new code.

Tap: opens a bottom sheet **Sync status** with the connection state, `Last synced
today, 6:40 PM` (from `lastSyncedAtProvider`, read-only), one row per non-empty
queue in plain words (`2 waiting to send, 1 not accepted`), a **Retry** button on
rows that have parked items, and for Split a **Review** button that opens the
existing WP-C8 needs-attention sheet. Semantics label on the strip, for example
`Offline, 3 changes waiting. Tap for details`.

## How it is wired

Files (all new, under `app/lib/features/sync_status/`):

| File | Job |
|---|---|
| `sync_status_providers.dart` | `SyncStatusMode`, immutable `SyncStatusSummary` (mode, pendingCount, attentionCount, lastSyncedAt), `syncStatusSummaryProvider`. Override this one provider in tests. |
| `queue_totals.dart` | `QueueRegistry` totals, `syncQueueTotalsProvider` (stream), per-queue lines and plain-language labels for the sheet |
| `reachability_monitor.dart` | `ReachabilityMonitor`: the debounced probe loop |
| `sync_retry.dart` | `syncRetryActionsProvider` (Retry by queue name), `syncNudgeProvider` |
| `sync_status_copy.dart` | all words |
| `sync_status_banner.dart` | `SyncStatusBanner` (layout wrapper) and `SyncStatusStrip` |
| `sync_status_sheet.dart` | the Sync status sheet |

`app/lib/main.dart` is the only existing source file touched: `PandaPayApp.build`
reads the router once and `builder` wraps the app in `SyncStatusBanner(navigatorKey:
router.routerDelegate.navigatorKey, child: child)` inside the text-scale
`MediaQuery`. `router.dart` / `_AppShell` are NOT touched (the plan's anchor
would have hidden the strip on sign-in and onboarding).

### Layout rules (proven by `sync_status_banner_test.dart`)

* The wrapper is a `Column(verticalDirection: up)` of `[Expanded(app), strip-slot]`.
  The slot is a `SizedBox.shrink()` while healthy, so the Navigator gets the same
  constraints, the same size and offset, and the same `MediaQuery` (padding,
  viewPadding, viewInsets, textScaler) as without the wrapper. Test pumps both and
  compares rects and `MediaQueryData`.
* The tree has the same shape in both states, so showing or hiding the strip does
  not recreate the Navigator or any screen (test: a stateful page is created once
  across three toggles).
* Visible: the strip occupies the top safe area itself (inset + line) and the app
  below gets `MediaQuery.removePadding(removeTop: true)`, so nothing is padded twice
  and nothing is covered. Bottom padding and keyboard insets are untouched.
* The strip clamps its own text scale to 1.5 so a large system font cannot turn it
  into a banner; the app below keeps the full scale.
* No animation (instant), so no frames of overlap while the inset moves.

### Why `verticalDirection: up` (a bug the obvious layout has)

A plain `Column[strip, app]` paints the strip BEFORE the Navigator. Every route's
modal barrier uses `BlockSemantics`, which drops the semantics of everything
painted earlier, so TalkBack/VoiceOver would never see the strip (the
`Semantics` label was not even in the tree). Laying the column out upwards keeps
the strip at the top visually but paints it after the app. Test:
`exposes one tappable semantics node with the full sentence`.

### Counts and cost (docs/PERFORMANCE_RULEBOOK.md)

* Totals use `QueueRegistry.countsFor` (one small COUNT per queue, account-scoped,
  tolerant of missing tables). No rows are loaded; nothing is read per frame.
* Recount triggers: first count 1.5 s after sign-in start (not during launch),
  queue-change events (`financialStoreRevisionProvider('transactions')`,
  `commandOutboxRevisionProvider`, a Retry nudge, reconnect, resume), coalesced to
  300 ms, plus a safety-net timer of 3 s while something is pending and 10 s
  otherwise. Nothing runs while the app is in the background or signed out.
  Only a changed value is emitted.
* The strip rebuilds only through `select`: the wrapper watches `summary.visible`,
  the strip watches the summary (a few ints).
* Excluded from "waiting to sync" (still listed in the sheet): `sms_intake` and
  `v2_outbox`. SMS parsing/upload is a background pipeline that can hold thousands
  of rows and changes with every message; counting it would flicker the strip.
  `shared_commands` and `split_documents` parked rows are not counted a second time
  (already in `needsAttentionCountProvider`).
* Reachability: nothing is probed at launch. The first probe is 3 s after the radio
  is known to be up; a failure is confirmed by a second probe 1.5 s later and only
  then reported; healthy re-probe every 60 s, unreachable every 10 s, resume
  re-probes at once, offline stops everything. Cost: one tiny `GET /app-status`
  per minute in the foreground while online (the knob is
  `ReachabilityMonitor.healthyInterval`).
* "Syncing" is a notifier whose 2 s timer restarts only when "online, reachable and
  something waiting" flips, so 3 -> 2 -> 1 keeps it and 0 drops it at once.

### Retry coverage

| Queue | Retry from the sheet |
|---|---|
| `sync_pending_changes` | yes (attempts reset; raw `UPDATE` in `sync_retry.dart`, no change to `SyncQueue`) |
| `transaction_outbox_entries` | yes (`retryParked(id)` per parked row) |
| `command_outbox` | yes (`retryParked(id)` per parked row) |
| `transaction_tag_outbox` | yes (`retryParked()`) |
| `foreign_payments_outbox` | yes (`retryParked()`) |
| Split commands / private splits | Review button, existing WP-C8 sheet (Retry/Discard) |
| `duplicate_resolution_outbox`, `statement_import` | listed, no button (no retry API; duplicates block after 5 counted failures) |

After a Retry: outbox flush request, `syncEngine.sync()` and a recount are nudged.

## How to verify

```
cd app
flutter test test/features/sync_status            # 71 tests: states, priority, debounce, layout, sheet, retry, DB counts
flutter test test/features/home/offline_banner_test.dart
flutter test test/app/router_test.dart test/app/keyboard_dismiss_test.dart test/app/router_onboarding_test.dart
flutter test test/widget_test.dart                # see "known failure" below
flutter test test/performance_guards_test.dart
flutter analyze lib/features/sync_status lib/main.dart test/features/sync_status
```

Manual, on a device or emulator:
1. Airplane mode on: strip `Offline · showing saved data` on Home, sign-in and any pushed screen; status bar is not double-padded, app bars sit directly under the strip.
2. Make an edit offline: `... · 1 waiting to sync`. Turn airplane mode off: strip disappears when the queue drains (a brief `Syncing 1 change…` only if it takes more than 2 s).
3. Connect to Wi-Fi with no internet (or block the API host): after about 5 s `Can't reach PandaPay · showing saved data`.
4. Tap the strip: Sync status sheet; Retry on a parked row.
5. Healthy online: no strip, and no layout change anywhere.

## Known gaps and notes

* `test/widget_test.dart` "Chunk 19: typing a real amount into Home updates the
  ranking amount" already fails on the base branch (WP-C2's 5-minute
  `outboxFlushProvider` timer is still pending when the test ends); verified by
  running it with `main.dart` reverted. The new strip adds one more timer in that
  test; the other `widget_test.dart` tests pass.
* Not run: `scripts/perf_smoke_android.sh` (no device). The added work at the app
  root is one `select` watch, one 10 s timer and a debounced probe.
* Light only in practice (`themeMode` is pinned to light); the strip also has a
  dark palette and is tested in dark mode.
* The sheet shows what is queued, not why each row failed; parked rows keep their
  own error in their tables.
* Resume-after-weeks staleness (L-13) is not implemented here beyond the "Last
  synced" line.
