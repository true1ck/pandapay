# WP-C4: notifications work offline

Findings: R-01, N-01, N-04 of `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`. Branch `offline/c4`.

## What changed

* **Preferences and muted merchants are kept on the phone.** They live in the
  account-scoped `ResponseCache` under `<namespace>:notification_preferences` and
  `<namespace>:notification_muted_merchants` (nothing is cached while signed out).
  `notificationPreferencesProvider` is now cache first: a cached copy is returned
  at once and refreshed in the background (at most every 30 s; the provider
  rebuilds only if the server's copy differs). With no cached copy it fetches
  live (8 s limit), and on any failure other than a rejected session it returns
  `NotificationPreferences.defaults` (the same values the server gives a new
  account: location and monthly report off, everything else on, cap 3, no quiet
  hours). It never holds an error, so the old "cached `AsyncError` for the whole
  session" cannot happen. It re-reads when the phone goes offline to online, and
  re-checks after 2 minutes if it fell back to the defaults.
  A rejected session (401) still gives `null`, as before.
* **Settings writes are optimistic.** `updateNotificationPreferences`,
  `muteNotificationMerchant`, `unmuteNotificationMerchant`
  (`notification_commands.dart`) change the phone's copy first, try the server
  live, and queue a command if that fails for a retryable reason. A refusal
  (4xx other than 401/408/429) restores the old copy and is rethrown. Offline
  toggles of the same account merge into one queued command (latest value per
  column wins); mute then unmute while queued cancel out. A background refresh
  never overwrites a copy that still has a queued change.
* **`NotificationGate.fire`** no longer needs the network. Order is now:
  preferences (cached/defaults), mute check (cached list), quiet hours, dedupe,
  daily cap, then the **OS banner**, then the inbox write. The dedupe key and
  the daily count are recorded once the banner was shown or the inbox row was
  sent or queued. If neither happened the key stays unset so the next sweep
  retries. An in-memory guard stops two overlapping sweeps delivering the same
  key twice.
* **Inbox rows are durable.** `recordAppNotification` still makes one immediate
  POST and still never throws. If the POST fails, or the phone is known to be
  offline, the row is queued as a `recordAppNotification` command in the
  existing `CommandOutbox`, replayed by the existing outbox flush, with a
  payload of category, title, body, severity, deepLink, dedupeKey, createdAt
  and a client mutation id. A row with no dedupe key gets `client:<mutation id>`
  when it is queued, so a replay cannot create a second row. The gate bounds the
  immediate POST to 4 s (`inboxTimeout`) before queueing.
* **Push registration** retries on reconnect (`PushNotificationService.onReconnected`,
  wired in `pushNotificationLifecycleProvider`), only when a retry was pending.

## Files

New: `lib/features/notifications/notification_commands.dart`,
`lib/features/notifications/notification_local_state.dart`,
`test/features/notifications/notification_offline_test.dart`.

Edited: `notification_gate.dart`, `push_notification_service.dart`,
`lib/data/notification_preferences_repository.dart` (`defaults`, `toJson`,
tolerant `daily_cap`), `lib/data/user_cards_repository.dart`
(`replayQueuedNotification`, `recordNotification` unchanged in signature),
`lib/features/settings/notification_settings_screen.dart` (writes go through
the helpers), `lib/app/providers.dart` (only: `notificationPreferencesProvider`
body, `recordAppNotification` body, `commandHandlersFor` signature plus one
spread line, its call site in `outboxFlushProvider`, three lines in
`pushNotificationLifecycleProvider`, two imports).

No migrations, no flags, no server change.

## Behaviour for an online, healthy user

Same moments, same dedupe, same quiet hours / cap / category / mute rules. The
differences a healthy user can notice: the OS banner appears before the inbox
row is written (it used to be after); preferences come from the cached copy and
are refreshed in the background, so a change made on another device reaches the
decision a refresh later instead of at the very next sweep.

## How to test

`flutter test test/features/notifications test/data/local_first test/features/auth/recovery_email_reminder_test.dart test/features/settings`

## Known gaps and notes

* Replaying a queued inbox row after the original POST actually succeeded (lost
  reply, or the 4 s limit passed) hits the server's upsert, which resets
  `read_at` and `created_at` for that dedupe key. The server ignores the
  `createdAt` we send. WP-S5's client mutation id column would let it keep the
  first row untouched.
* The inbox screen itself is still network-first (R-07, WP-C11); a queued row
  shows there after the replay.
* Scheduled / OS-alarm notifications are not part of this package (N-02, WP-C14).
* If a push registration fails while the device is offline at startup, the
  startup retry is also brought forward by `onReconnected`.
