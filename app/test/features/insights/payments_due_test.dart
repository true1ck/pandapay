import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';

/// Design 13's due-date arithmetic. The subtle part is month rollover: a
/// due day of 31 has to land somewhere real in a 30-day month, and the
/// statement-cycle start has to walk *backwards* across a year boundary
/// without landing in the future.

void main() {
  group('nextOccurrenceOf', () {
    test('returns today when the due day is today', () {
      // Boundary that matters: a statement due today is due, not due next
      // month. Getting this wrong hides a payment on the day it is owed.
      expect(nextOccurrenceOf(15, DateTime(2026, 8, 15)), DateTime(2026, 8, 15));
    });

    test('stays in this month when the day is still ahead', () {
      expect(nextOccurrenceOf(20, DateTime(2026, 8, 11)), DateTime(2026, 8, 20));
    });

    test('rolls to next month once the day has passed', () {
      expect(nextOccurrenceOf(5, DateTime(2026, 8, 11)), DateTime(2026, 9, 5));
    });

    test('rolls across a year boundary', () {
      expect(nextOccurrenceOf(5, DateTime(2026, 12, 11)), DateTime(2027, 1, 5));
    });

    test('clamps a 31st due day into a 30-day month', () {
      // September has 30 days; an issuer bills on the 30th, not October 1st.
      expect(nextOccurrenceOf(31, DateTime(2026, 9, 15)), DateTime(2026, 9, 30));
    });

    test('clamps a 31st due day into February', () {
      expect(nextOccurrenceOf(31, DateTime(2026, 2, 10)), DateTime(2026, 2, 28));
    });

    test('clamps into a leap February', () {
      expect(nextOccurrenceOf(30, DateTime(2028, 2, 10)), DateTime(2028, 2, 29));
    });
  });

  group('previousOccurrenceOf', () {
    test('returns today when the statement day is today', () {
      expect(previousOccurrenceOf(15, DateTime(2026, 8, 15)), DateTime(2026, 8, 15));
    });

    test('stays in this month when the day has already passed', () {
      expect(previousOccurrenceOf(5, DateTime(2026, 8, 11)), DateTime(2026, 8, 5));
    });

    test('walks back a month when the day is still ahead', () {
      expect(previousOccurrenceOf(20, DateTime(2026, 8, 11)), DateTime(2026, 7, 20));
    });

    test('walks back across a year boundary', () {
      expect(previousOccurrenceOf(20, DateTime(2026, 1, 11)), DateTime(2025, 12, 20));
    });

    test('clamps a 31st statement day into a short previous month', () {
      // Walking back from 10 May with a 31st statement day lands in April,
      // which has 30 days.
      expect(previousOccurrenceOf(31, DateTime(2026, 5, 10)), DateTime(2026, 4, 30));
    });

    test('never returns a date in the future', () {
      // The cycle start bounds a "spend since" sum; a future value would
      // silently zero it out.
      for (var day = 1; day <= 31; day++) {
        final from = DateTime(2026, 3, 15);
        expect(
          previousOccurrenceOf(day, from).isAfter(from),
          isFalse,
          reason: 'statement day $day resolved to a future cycle start',
        );
      }
    });
  });
}
