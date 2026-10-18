import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/notifications/notification_triggers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('subscription reminder windows', () {
    final now = DateTime(2026, 10, 18, 23, 59);
    test('early reminder covers three days and catches up at two days', () {
      expect(NotificationTriggerRunner.subscriptionReminderStage(DateTime(2026, 10, 21), now), 3);
      expect(NotificationTriggerRunner.subscriptionReminderStage(DateTime(2026, 10, 20), now), 3);
    });
    test('tomorrow uses a separate reminder stage', () {
      expect(NotificationTriggerRunner.subscriptionReminderStage(DateTime(2026, 10, 19), now), 1);
    });
    test('no reminder on or after renewal or too early', () {
      for (final day in [17, 18, 22]) {
        expect(NotificationTriggerRunner.subscriptionReminderStage(DateTime(2026, 10, day), now), isNull);
      }
    });
    test('calendar days work across year boundaries and UTC date values', () {
      expect(NotificationTriggerRunner.subscriptionReminderStage(DateTime.utc(2027, 1, 1), DateTime(2026, 12, 29, 23)), 3);
    });
  });
  group('NotificationTriggerRunner.capPeriodBucket', () {
    test('calendarMonth buckets by year-month', () {
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.calendarMonth, DateTime(2026, 3, 15)), '2026-3');
    });

    test('statementCycle buckets the same as calendarMonth (no exact cycle boundary is exposed client-side)', () {
      expect(
        NotificationTriggerRunner.capPeriodBucket(CapPeriod.statementCycle, DateTime(2026, 3, 15)),
        NotificationTriggerRunner.capPeriodBucket(CapPeriod.calendarMonth, DateTime(2026, 3, 15)),
      );
    });

    test('quarter buckets correctly across all four quarters', () {
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.quarter, DateTime(2026, 1, 1)), '2026-Q1');
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.quarter, DateTime(2026, 3, 31)), '2026-Q1');
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.quarter, DateTime(2026, 4, 1)), '2026-Q2');
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.quarter, DateTime(2026, 7, 1)), '2026-Q3');
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.quarter, DateTime(2026, 12, 31)), '2026-Q4');
    });

    test('halfYear buckets January-June as H1 and July-December as H2', () {
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.halfYear, DateTime(2026, 6, 30)), '2026-H1');
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.halfYear, DateTime(2026, 7, 1)), '2026-H2');
    });

    test('annual buckets by year only', () {
      expect(NotificationTriggerRunner.capPeriodBucket(CapPeriod.annual, DateTime(2026, 12, 31)), '2026');
    });

    test('lifetime is one constant bucket regardless of date', () {
      expect(
        NotificationTriggerRunner.capPeriodBucket(CapPeriod.lifetime, DateTime(2020, 1, 1)),
        NotificationTriggerRunner.capPeriodBucket(CapPeriod.lifetime, DateTime(2030, 1, 1)),
      );
    });

    test('a new calendar month produces a different bucket than the previous one', () {
      expect(
        NotificationTriggerRunner.capPeriodBucket(CapPeriod.calendarMonth, DateTime(2026, 3, 31)),
        isNot(NotificationTriggerRunner.capPeriodBucket(CapPeriod.calendarMonth, DateTime(2026, 4, 1))),
      );
    });
  });
}
