// Which subscriptions get a "renews tomorrow" notice. It must be the same list
// the Subscriptions page shows as still billing, and the day must be the
// person's own calendar day (a date-only SMS is IST midnight, which is the
// evening before in UTC).
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/notifications/notification_triggers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

RecurringSeries _series(
  String id,
  String name, {
  required DateTime renews,
  String lifecycleStatus = 'active',
  bool reviewCandidate = false,
}) => RecurringSeries(
  id: id,
  displayName: name,
  typicalAmount: Money.fromRupees(649),
  cadenceDays: 30,
  occurrenceCount: 3,
  annualCost: Money.fromRupees(7788),
  nextExpectedOn: renews,
  lifecycleStatus: lifecycleStatus,
  setupConfirmed: true,
  reviewCandidate: reviewCandidate,
);

void main() {
  final now = DateTime(2026, 11, 9, 10);
  final tomorrow = DateTime(2026, 11, 10);

  group('who gets a renewal reminder', () {
    test('a plain subscription renewing tomorrow does', () {
      final due = NotificationTriggerRunner.subscriptionsDueForReminder([
        _series('netflix', 'Netflix', renews: tomorrow),
      ], now);
      expect([for (final (s, stage) in due) (s.id, stage)], [('netflix', 1)]);
    });

    test('a telecom, a lender and an insurance row do not, though they renew tomorrow', () {
      final due = NotificationTriggerRunner.subscriptionsDueForReminder([
        _series('netflix', 'Netflix', renews: tomorrow),
        _series('airtel', 'Airtel Postpaid', renews: tomorrow),
        _series('lender', 'Example Finance Ltd', renews: tomorrow),
        _series('insurer', 'Example Life Insurance Policy', renews: tomorrow),
      ], now);
      expect([for (final (s, _) in due) s.id], ['netflix']);
    });

    test('a paused or cancelled plan and a merely suspected one do not', () {
      final due = NotificationTriggerRunner.subscriptionsDueForReminder([
        _series('paused', 'Spotify', renews: tomorrow, lifecycleStatus: 'paused'),
        _series('cancelled', 'Hotstar', renews: tomorrow, lifecycleStatus: 'cancelled'),
        _series('guess', 'Netflix', renews: tomorrow, reviewCandidate: true),
      ], now);
      expect(due, isEmpty);
    });
  });

  group('the day is the local calendar day', () {
    test('a renewal stored as the previous evening in UTC is still tomorrow, not today', () {
      // Local midnight of 10 Nov, as the UTC instant it is stored as. In India
      // that is 18:30 on 9 Nov UTC; reading its UTC date would say "today".
      final stored = tomorrow.toUtc();
      expect(NotificationTriggerRunner.subscriptionReminderStage(stored, now), 1);
    });

    test('and the same instant seen from the due-list is tomorrow too', () {
      final due = NotificationTriggerRunner.subscriptionsDueForReminder([
        _series('netflix', 'Netflix', renews: tomorrow.toUtc()),
      ], now);
      expect([for (final (_, stage) in due) stage], [1]);
    });
  });
}
