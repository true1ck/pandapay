# WP-C14: scheduled local reminders (work with the app closed)

Findings N-02, N-03 of the offline-first master plan. Branch `offline/c14`. Decision D4: **inexact** scheduling
(`AndroidScheduleMode.inexactAllowWhileIdle`); no `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`. The OS may deliver a
reminder a little late (Doze).

## What changed

* `timezone: ^0.10.1` is now a direct dependency (already resolved at 0.10.1). The `latest_10y` tz table is initialised once,
  zone from `deviceTimeZoneProvider` (`Asia/Kolkata`).
* `features/notifications/scheduled_reminders.dart`:
  * `planReminders` is pure. Sources: bills/commitments (unpaid, not dismissed; 3 days, 1 day and the day), subscription
    renewals (`buildSubscriptionView(...).active`, 1 day), card due days from `paymentsDueProvider` (3 and 1 days; **only
    cards the user switched "remind me" on for in `dueDateRemindersProvider`**). Reminders fire at 09:00 local.
  * Rules applied at schedule time from the cached preferences (`notificationPreferencesProvider`): category `bills` off or
    unknown prefs plans nothing; times inside quiet hours move to the end of the quiet window; at most `dailyCap` per day (the
    most urgent kept); never in the past; at most 50 pending (earliest first; iOS keeps 64).
  * Ids are FNV-1a of `kind|entityId|offset`, masked to int32, so rescheduling replaces and never duplicates.
  * Bodies carry no amounts ("A bill is due tomorrow. Open PandaPay for details."). The app has no lock-screen privacy
    setting and the gate formats no bodies, so the safe form is always used.
  * `syncReminders` diffs against the OS: cancels our pending ids no longer wanted (paid, dismissed, toggled off, category
    off), schedules new or changed ones (a payload carries the time and a content hash), leaves identical ones alone. Pending
    ones are recognised by the payload prefix `pp_reminder:`.
  * `ReminderScheduler` interface (fake in tests) and `PluginReminderScheduler` (zonedSchedule with the 18.0.1 required
    `uiLocalNotificationDateInterpretation` and `androidScheduleMode`).
  * `reminderLifecycleProvider` (one line in `_AppShell`, `router.dart`): reschedules on resume, when user cards, commitments,
    the recurring report or the reminder toggles change, and when the account changes. It goes through
    `startupWorkSchedulerProvider` (key `reminder-sync`, 3 s delay, coalesced), so no timer outlives the provider. Nothing runs
    while signed out; going signed-out cancels all our reminders.
* Android manifest: `RECEIVE_BOOT_COMPLETED`, `ScheduledNotificationReceiver`, `ScheduledNotificationBootReceiver` (BOOT_COMPLETED,
  MY_PACKAGE_REPLACED, QUICKBOOT_POWERON, HTC QUICKBOOT_POWERON). Existing entries untouched.
* iOS `AppDelegate.swift`: `import UserNotifications` and `UNUserNotificationCenter.current().delegate = self` (needed for
  foreground display). **Needs a device check**; entitlements and background modes untouched.
* Sign-out: `clearWidgetsAndNotifications` already calls `plugin.cancelAll()`, which also drops scheduled reminders;
  the lifecycle provider also cancels ours when the namespace becomes `signed-out`.

## Behaviour notes / limits

* If notifications are not permitted (`areNotificationsEnabled()` false / iOS `checkPermissions`) nothing is scheduled. No new
  permission prompt was added.
* The gate's daily cap is not reduced by alerts already fired today by the in-app triggers; the plan only applies the cap to
  scheduled reminders per day.
* Card reminders depend on `paymentsDueProvider` having data; it is read at run time (not eagerly listened to), so changes to
  card due dates are picked up at the next resume/cards/commitments change.
* The existing in-process triggers (`_checkBillsDue`, `_checkSubscriptions`) still run; they use different notification ids and
  dedupe keys, so a person may see the OS reminder and the in-app one for the same bill. Retiring one of them is a follow-up.
* Geofence restore after reboot is out of scope (separate item).

## Tests

`test/features/notifications/scheduled_reminders_test.dart` (17): offsets, past-skipping, ids, category/prefs off, quiet-hours
shift (plain and wrapping), daily cap, rolling window, paid/dismissed excluded, card toggle, no amounts in bodies, sync
idempotence / cancel / not-permitted, lifecycle (schedules signed in, nothing when signed out, cancels when a bill is paid),
manifest sanity.

## Needs a real device

Alarms surviving reboot and Doze (Android 12-15), delivery delay with inexact alarms, boot-receiver rescheduling after
reboot/app update, OEM battery killers, iOS foreground presentation with the new delegate, iOS 64-pending limit.
