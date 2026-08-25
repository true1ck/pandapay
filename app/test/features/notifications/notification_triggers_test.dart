import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/notifications/notification_triggers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
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
