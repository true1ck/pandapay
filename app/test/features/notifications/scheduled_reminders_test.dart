import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/notification_preferences_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart'
    show DuePayment, paymentsDueProvider;
import 'package:pandapay/features/notifications/scheduled_reminders.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

// WP-C14. Synthetic data only.

NotificationPreferences prefs({
  bool bills = true,
  int cap = 3,
  String? qs,
  String? qe,
}) => NotificationPreferences(
  categoryLocation: false,
  categoryCaps: true,
  categoryMilestones: true,
  categoryFeeWaivers: true,
  categoryBills: bills,
  categoryExpiry: true,
  categoryMonthlyReport: false,
  categoryNeedsReview: true,
  quietHoursStart: qs,
  quietHoursEnd: qe,
  dailyCap: cap,
);

ReminderSource src(
  String id,
  DateTime due, {
  List<int> offs = const [3, 1, 0],
  String kind = 'bill',
}) => ReminderSource(
  kind: kind,
  entityId: id,
  title: 'Test bill $id',
  dueDay: due,
  offsetsDays: offs,
);

class FakeScheduler implements ReminderScheduler {
  bool allowed = true;
  final Map<int, String> live = {};
  final scheduled = <int>[];
  int cancelAllCalls = 0;
  @override
  Future<bool> notificationsAllowed() async => allowed;
  @override
  Future<Map<int, String>> pending() async => Map.of(live);
  @override
  Future<void> schedule(PlannedReminder r) async {
    live[r.id] = r.payload;
    scheduled.add(r.id);
  }

  @override
  Future<void> cancel(int id) async => live.remove(id);
  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    live.clear();
  }
}

class _FixedClock implements Clock {
  _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final now = DateTime(2030, 1, 10, 8);

  group('planReminders', () {
    test('3d, 1d and on-the-day at 09:00; past ones skipped', () {
      final plan = planReminders(
        sources: [src('a', DateTime(2030, 1, 12))], // 3d = Jan 9 (past)
        now: now,
        prefs: prefs(),
      );
      expect(plan.map((r) => r.offsetDays), [1, 0]);
      expect(plan.first.at, DateTime(2030, 1, 11, 9));
      expect(plan.last.at, DateTime(2030, 1, 12, 9));
    });

    test('nothing at or before now', () {
      final plan = planReminders(
        sources: [
          src('a', DateTime(2030, 1, 10), offs: [0]),
        ],
        now: DateTime(2030, 1, 10, 9),
        prefs: prefs(),
      );
      expect(plan, isEmpty);
    });

    test('ids are deterministic, int32 and distinct per offset', () {
      final a = reminderId('bill', 'x', 3);
      expect(reminderId('bill', 'x', 3), a);
      expect(reminderId('bill', 'x', 1), isNot(a));
      expect(reminderId('sub', 'x', 3), isNot(a));
      expect(a, inInclusiveRange(0, 0x7fffffff));
    });

    test('category off or unknown prefs plans nothing', () {
      final s = [src('a', DateTime(2030, 2, 1))];
      expect(
        planReminders(sources: s, now: now, prefs: prefs(bills: false)),
        isEmpty,
      );
      expect(planReminders(sources: s, now: now, prefs: null), isEmpty);
    });

    test('quiet hours shift to the first allowed time', () {
      final plan = planReminders(
        sources: [
          src('a', DateTime(2030, 2, 1), offs: [0]),
        ],
        now: now,
        prefs: prefs(qs: '08:00:00', qe: '10:30:00'),
      );
      expect(plan.single.at, DateTime(2030, 2, 1, 10, 30));
      // Wrapping window: 22:00-11:00 also covers 09:00.
      final wrap = planReminders(
        sources: [
          src('a', DateTime(2030, 2, 1), offs: [0]),
        ],
        now: now,
        prefs: prefs(qs: '22:00', qe: '11:00'),
      );
      expect(wrap.single.at, DateTime(2030, 2, 1, 11));
    });

    test('daily cap keeps the most urgent per day', () {
      final due = DateTime(2030, 2, 1);
      final plan = planReminders(
        sources: [
          for (var i = 0; i < 5; i++) src('d$i', due, offs: [0]),
          src('early', DateTime(2030, 2, 4), offs: [3]),
        ],
        now: now,
        prefs: prefs(cap: 2),
      );
      expect(plan.length, 2);
      expect(plan.every((r) => r.at.day == 1), isTrue);
    });

    test('rolling window keeps the earliest N', () {
      final plan = planReminders(
        sources: [
          for (var i = 0; i < 80; i++)
            src('b$i', DateTime(2030, 3, 1 + i), offs: [0]),
        ],
        now: now,
        prefs: prefs(cap: 5),
      );
      expect(plan.length, reminderWindow);
      expect(plan.first.at, DateTime(2030, 3, 1, 9));
      for (var i = 1; i < plan.length; i++) {
        expect(plan[i].at.isAfter(plan[i - 1].at), isTrue);
      }
    });

    test('paid and dismissed commitments are not planned', () {
      Commitment c(String id, CommitmentStatus s) => Commitment(
        id: id,
        title: 'Test $id',
        category: CommitmentCategory.utility,
        dueOn: DateTime(2030, 2, 1),
        status: s,
      );
      final s = billSources([
        c('due', CommitmentStatus.due),
        c('paid', CommitmentStatus.paid),
        c('gone', CommitmentStatus.dismissed),
      ]);
      expect(s.map((e) => e.entityId), ['due']);
    });

    test('card sources only for cards with the reminder toggle on', () {
      final s = cardSources([
        ('c1', 'Test Card', DateTime(2030, 2, 1)),
        ('c2', 'Other', DateTime(2030, 2, 2)),
      ], {'c2'});
      expect(s.map((e) => e.entityId), ['c2']);
      expect(s.single.offsetsDays, [3, 1]);
    });

    test('bodies carry no amounts', () {
      final plan = planReminders(
        sources: [src('a', DateTime(2030, 2, 1), offs: [0])],
        now: now,
        prefs: prefs(),
      );
      expect(plan.every((r) => !r.body.contains(RegExp(r'\d'))), isTrue);
    });
  });

  group('syncReminders', () {
    final plan = planReminders(
      sources: [src('a', DateTime(2030, 2, 1)), src('b', DateTime(2030, 2, 5))],
      now: now,
      prefs: prefs(),
    );

    test('schedules, then is idempotent', () async {
      final s = FakeScheduler();
      await syncReminders(s, plan);
      expect(s.live.length, plan.length);
      s.scheduled.clear();
      await syncReminders(s, plan);
      expect(s.scheduled, isEmpty);
    });

    test('cancels an entity that was paid or dismissed', () async {
      final s = FakeScheduler();
      await syncReminders(s, plan);
      final left = plan.where((r) => r.entityId != 'a').toList();
      await syncReminders(s, left);
      expect(s.live.keys.toSet(), left.map((r) => r.id).toSet());
    });

    test('nothing scheduled when notifications are not permitted', () async {
      final s = FakeScheduler()..allowed = false;
      await syncReminders(s, plan);
      expect(s.live, isEmpty);
    });
  });

  group('reminderLifecycleProvider', () {
    ProviderContainer make(
      FakeScheduler s, {
      required String ns,
      List<Commitment>? commitments,
    }) {
      final list =
          commitments ??
          [
            Commitment(
              id: 'x',
              title: 'Test bill',
              category: CommitmentCategory.utility,
              dueOn: DateTime(2030, 2, 1),
            ),
          ];
      final c = ProviderContainer(
        overrides: [
          reminderSchedulerProvider.overrideWithValue(s),
          reminderDebounceProvider.overrideWithValue(Duration.zero),
          cacheNamespaceProvider.overrideWithValue(ns),
          clockProvider.overrideWithValue(_FixedClock(now)),
          notificationPreferencesProvider.overrideWith((_) async => prefs()),
          recurringReportProvider.overrideWith((_) async => null),
          paymentsDueProvider.overrideWith((_) async => const <DuePayment>[]),
          commitmentsProvider.overrideWith((_) async => list),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('schedules when signed in', () async {
      final s = FakeScheduler();
      make(s, ns: 'user:t').read(reminderLifecycleProvider);
      await settle();
      expect(s.live, isNotEmpty);
    });

    test('does nothing while signed out', () async {
      final s = FakeScheduler();
      make(s, ns: 'signed-out').read(reminderLifecycleProvider);
      await settle();
      expect(s.live, isEmpty);
      expect(s.scheduled, isEmpty);
    });

    test('re-plans when commitments change (paid -> cancelled)', () async {
      final s = FakeScheduler();
      final c = make(s, ns: 'user:t');
      c.read(reminderLifecycleProvider);
      await settle();
      expect(s.live, isNotEmpty);
      c.updateOverrides([
        reminderSchedulerProvider.overrideWithValue(s),
        reminderDebounceProvider.overrideWithValue(Duration.zero),
        cacheNamespaceProvider.overrideWithValue('user:t'),
        clockProvider.overrideWithValue(_FixedClock(now)),
        notificationPreferencesProvider.overrideWith((_) async => prefs()),
        recurringReportProvider.overrideWith((_) async => null),
        paymentsDueProvider.overrideWith((_) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith(
          (_) async => [
            Commitment(
              id: 'x',
              title: 'Test bill',
              category: CommitmentCategory.utility,
              dueOn: DateTime(2030, 2, 1),
              status: CommitmentStatus.paid,
            ),
          ],
        ),
      ]);
      c.invalidate(commitmentsProvider);
      await settle();
      expect(s.live, isEmpty);
    });
  });

  test('manifest declares boot permission and both receivers', () {
    final xml = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(xml, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(
      xml,
      contains('flutterlocalnotifications.ScheduledNotificationReceiver'),
    );
    expect(
      xml,
      contains('flutterlocalnotifications.ScheduledNotificationBootReceiver'),
    );
    for (final a in [
      'android.intent.action.BOOT_COMPLETED',
      'android.intent.action.MY_PACKAGE_REPLACED',
      'android.intent.action.QUICKBOOT_POWERON',
      'com.htc.intent.action.QUICKBOOT_POWERON',
    ]) {
      expect(xml, contains(a));
    }
    expect(xml, isNot(contains('SCHEDULE_EXACT_ALARM')));
    expect(xml, isNot(contains('USE_EXACT_ALARM')));
    // Tags balance (a parse sanity check without an XML dependency).
    expect(RegExp('<application').allMatches(xml).length, 1);
    expect(RegExp('</application>').allMatches(xml).length, 1);
    expect(
      RegExp('<receiver').allMatches(xml).length,
      RegExp(r'</receiver>|<receiver[^>]*/>').allMatches(xml).length,
    );
  });
}
