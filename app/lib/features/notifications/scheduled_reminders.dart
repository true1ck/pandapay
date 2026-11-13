import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../app/providers.dart';
import '../../data/commitments_repository.dart';
import '../../data/notification_preferences_repository.dart';
import '../../data/spend_reports_repository.dart' show RecurringSeries;
import '../insights/payments_due_screen.dart' show paymentsDueProvider;
import '../insights/subscription_view.dart' show buildSubscriptionView;
import 'notification_branding.dart';
import 'notification_gate.dart';

/// WP-C14: OS-scheduled local reminders, so a bill / renewal / card due date
/// reaches the person with the app closed. Planning is pure (see
/// [planReminders]) and uses WALL-CLOCK times in the app's time zone; only
/// [PluginReminderScheduler] turns them into zoned times.
///
/// Rules are the gate's, evaluated at schedule time from the cached
/// preferences: category `bills`, quiet hours (shifted to the first allowed
/// minute), daily cap. Bodies carry no amounts (lock-screen privacy; the app
/// has no privacy setting, so the safe form is used always).
/// Scheduling is INEXACT (decision D4): the OS may deliver a little late.

/// A day-level thing to remind about.
class ReminderSource {
  const ReminderSource({
    required this.kind,
    required this.entityId,
    required this.title,
    required this.dueDay,
    required this.offsetsDays,
  });

  final String kind; // 'bill' | 'sub' | 'card'
  final String entityId;
  final String title;

  /// Calendar day only (year/month/day are what count).
  final DateTime dueDay;

  /// Days before [dueDay] to remind (0 = on the day).
  final List<int> offsetsDays;
}

class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.kind,
    required this.entityId,
    required this.offsetDays,
    required this.at,
    required this.title,
    required this.body,
  });

  final int id;
  final String kind;
  final String entityId;
  final int offsetDays;

  /// Wall-clock time in the app's time zone.
  final DateTime at;
  final String title;
  final String body;

  /// Marks our pending notifications among any others, and carries what
  /// changes the content so an unchanged reminder is not rescheduled.
  String get payload =>
      '$reminderPayloadPrefix${at.millisecondsSinceEpoch}:${Object.hash(title, body)}';
}

const reminderPayloadPrefix = 'pp_reminder:';
const reminderWindow = 50; // iOS keeps 64 pending; stay well below.
const reminderHour = 9;

/// Stable id in int32 range, so rescheduling replaces and never duplicates.
int reminderId(String kind, String entityId, int offsetDays) {
  var h = 0x811c9dc5; // FNV-1a
  for (final u in '$kind|$entityId|$offsetDays'.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

DateTime _shiftOutOfQuiet(NotificationPreferences prefs, DateTime at) {
  if (!NotificationGate.inQuietHours(prefs, at)) return at;
  final parts = prefs.quietHoursEnd!.split(':');
  var end = DateTime(
    at.year,
    at.month,
    at.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
  if (!end.isAfter(at)) end = end.add(const Duration(days: 1));
  return end;
}

String _bodyFor(String kind, int offset) {
  final when = switch (offset) {
    0 => 'today',
    1 => 'tomorrow',
    _ => 'in $offset days',
  };
  return switch (kind) {
    'sub' => 'A subscription renews $when. Open PandaPay to review it.',
    'card' => 'A card payment is due $when. Open PandaPay for details.',
    _ => 'A bill is due $when. Open PandaPay for details.',
  };
}

/// Pure. [now] is wall-clock in the app's time zone; [prefs] null means
/// "unknown / signed out" and plans nothing.
List<PlannedReminder> planReminders({
  required Iterable<ReminderSource> sources,
  required DateTime now,
  required NotificationPreferences? prefs,
  int window = reminderWindow,
}) {
  if (prefs == null || !NotificationGate.categoryEnabled(prefs, 'bills')) {
    return const [];
  }
  final byId = <int, PlannedReminder>{};
  for (final s in sources) {
    for (final off in s.offsetsDays) {
      final day = DateTime(s.dueDay.year, s.dueDay.month, s.dueDay.day - off);
      final at = _shiftOutOfQuiet(
        prefs,
        DateTime(day.year, day.month, day.day, reminderHour),
      );
      if (!at.isAfter(now)) continue; // never schedule in the past
      final id = reminderId(s.kind, s.entityId, off);
      byId[id] = PlannedReminder(
        id: id,
        kind: s.kind,
        entityId: s.entityId,
        offsetDays: off,
        at: at,
        title: s.title,
        body: _bodyFor(s.kind, off),
      );
    }
  }
  // Daily cap: keep the most urgent (smallest offset) per day.
  final perDay = <String, List<PlannedReminder>>{};
  for (final r in byId.values) {
    perDay
        .putIfAbsent('${r.at.year}-${r.at.month}-${r.at.day}', () => [])
        .add(r);
  }
  final cap = prefs.dailyCap < 0 ? 0 : prefs.dailyCap;
  final kept = <PlannedReminder>[];
  for (final day in perDay.values) {
    day.sort((a, b) {
      final c = a.offsetDays.compareTo(b.offsetDays);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    kept.addAll(day.take(cap));
  }
  kept.sort((a, b) {
    final c = a.at.compareTo(b.at);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return kept.take(window).toList();
}

// ---- sources from the same local data the triggers use --------------------

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

List<ReminderSource> billSources(Iterable<Commitment> commitments) => [
  for (final c in commitments)
    if (c.status != CommitmentStatus.paid &&
        c.status != CommitmentStatus.dismissed)
      ReminderSource(
        kind: 'bill',
        entityId: c.id,
        title: c.title,
        dueDay: _day(c.dueOn.toLocal()),
        offsetsDays: const [3, 1, 0],
      ),
];

List<ReminderSource> subscriptionSources(Iterable<RecurringSeries> series) => [
  for (final s in buildSubscriptionView(series.toList()).active)
    if (s.nextExpectedOn != null && s.typicalAmount.paise > 0)
      ReminderSource(
        kind: 'sub',
        entityId: s.id,
        title: '${s.displayName} renews soon',
        dueDay: _day(s.nextExpectedOn!.toLocal()),
        offsetsDays: const [1],
      ),
];

/// Card due days; only cards the user switched "remind me" on for
/// (dueDateRemindersProvider) are included.
List<ReminderSource> cardSources(
  Iterable<(String id, String name, DateTime dueOn)> cards,
  Set<String> enabledCardIds,
) => [
  for (final (id, name, dueOn) in cards)
    if (enabledCardIds.contains(id))
      ReminderSource(
        kind: 'card',
        entityId: id,
        title: '$name payment due',
        dueDay: _day(dueOn),
        offsetsDays: const [3, 1],
      ),
];

// ---- scheduler -------------------------------------------------------------

abstract class ReminderScheduler {
  /// False when the OS notification permission is not granted.
  Future<bool> notificationsAllowed();

  /// Ids -> payload of OUR pending reminders only.
  Future<Map<int, String>> pending();
  Future<void> schedule(PlannedReminder r);
  Future<void> cancel(int id);
  Future<void> cancelAll();
}

/// Brings the OS in line with [plan]: cancels ours that are no longer wanted,
/// (re)schedules new or changed ones, leaves identical ones alone. With
/// notifications not permitted nothing is scheduled.
Future<void> syncReminders(
  ReminderScheduler scheduler,
  List<PlannedReminder> plan,
) async {
  if (plan.isNotEmpty && !await scheduler.notificationsAllowed()) {
    plan = const [];
  }
  final pending = await scheduler.pending();
  final wanted = {for (final r in plan) r.id};
  for (final id in pending.keys) {
    if (!wanted.contains(id)) await scheduler.cancel(id);
  }
  for (final r in plan) {
    if (pending[r.id] != r.payload) await scheduler.schedule(r);
  }
}

class PluginReminderScheduler implements ReminderScheduler {
  PluginReminderScheduler(this._plugin, {required this.timeZone});

  final FlutterLocalNotificationsPlugin _plugin;
  final String timeZone;
  static bool _tzReady = false;
  bool _initialized = false;

  Future<void> _init() async {
    if (!_tzReady) {
      // ponytail: 10-year tz table; Asia/Kolkata has no DST. Switch to
      // latest.dart before 2033.
      tz_data.initializeTimeZones();
      _tzReady = true;
    }
    if (!_initialized) {
      await _plugin.initialize(NotificationBranding.initializationSettings);
      _initialized = true;
    }
  }

  @override
  Future<bool> notificationsAllowed() async {
    await _init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.areNotificationsEnabled() ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final perms = await ios?.checkPermissions();
    return perms?.isEnabled ?? false;
  }

  @override
  Future<Map<int, String>> pending() async {
    await _init();
    return {
      for (final p in await _plugin.pendingNotificationRequests())
        if (p.payload?.startsWith(reminderPayloadPrefix) ?? false)
          p.id: p.payload!,
    };
  }

  @override
  Future<void> schedule(PlannedReminder r) async {
    await _init();
    final loc = tz.getLocation(timeZone);
    await _plugin.zonedSchedule(
      r.id,
      r.title,
      r.body,
      tz.TZDateTime(loc, r.at.year, r.at.month, r.at.day, r.at.hour, r.at.minute),
      NotificationBranding.alertDetails,
      payload: r.payload,
      // D4: inexact; no exact-alarm permission.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  @override
  Future<void> cancel(int id) async {
    await _init();
    await _plugin.cancel(id);
  }

  @override
  Future<void> cancelAll() async {
    for (final id in (await pending()).keys) {
      await _plugin.cancel(id);
    }
  }
}

/// Quiet period before rescheduling after a change; tests shorten it.
final reminderDebounceProvider = Provider<Duration>((_) => const Duration(seconds: 2));

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => PluginReminderScheduler(
    ref.watch(localNotificationsPluginProvider),
    timeZone: ref.watch(deviceTimeZoneProvider),
  ),
);

/// Builds the plan from the providers' current local data.
Future<List<PlannedReminder>> currentReminderPlan(Ref ref, DateTime now) async {
  final prefs = await ref.read(notificationPreferencesProvider.future);
  final commitments = ref.read(commitmentsProvider).valueOrNull ?? const [];
  final report = ref.read(recurringReportProvider).valueOrNull;
  final due = ref.read(paymentsDueProvider).valueOrNull ?? const [];
  final cardToggles = ref.read(dueDateRemindersProvider);
  return planReminders(
    now: now,
    prefs: prefs,
    sources: [
      ...billSources(commitments),
      ...subscriptionSources(report?.series ?? const []),
      ...cardSources([
        for (final d in due)
          (
            d.card.id,
            d.card.nickname?.isNotEmpty == true
                ? d.card.nickname!
                : d.card.cardName,
            d.dueOn,
          ),
      ], cardToggles),
    ],
  );
}

/// Reschedules on resume and on data changes (debounced), does nothing while
/// signed out, and cancels everything when the account goes away. The one
/// debounce timer is cancelled on dispose, so nothing is left pending.
final reminderLifecycleProvider = Provider<void>((ref) {
  final scheduler = ref.read(reminderSchedulerProvider);
  Timer? debounce;
  var disposed = false;

  Future<void> run() async {
    if (disposed) return;
    try {
      if (ref.read(cacheNamespaceProvider) == 'signed-out') return;
      final plan = await currentReminderPlan(ref, ref.read(clockProvider).now());
      if (disposed) return;
      await syncReminders(scheduler, plan);
    } catch (_) {
      // Best effort: a missed schedule is retried on the next change/resume.
    }
  }

  void request() {
    debounce?.cancel();
    debounce = Timer(ref.read(reminderDebounceProvider), () => unawaited(run()));
  }

  ref.onDispose(() {
    disposed = true;
    debounce?.cancel();
  });
  final listener = AppLifecycleListener(onResume: request);
  ref.onDispose(listener.dispose);

  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    if (next == 'signed-out') {
      debounce?.cancel();
      unawaited(scheduler.cancelAll().catchError((_) {}));
    } else {
      request();
    }
  });
  ref.listen<Object?>(commitmentsProvider, (_, _) => request());
  ref.listen<Object?>(recurringReportProvider, (_, _) => request());
  ref.listen<Object?>(paymentsDueProvider, (_, _) => request());
  ref.listen<Object?>(dueDateRemindersProvider, (_, _) => request());
  ref.listen<Object?>(notificationPreferencesProvider, (_, _) => request());
  request();
});
