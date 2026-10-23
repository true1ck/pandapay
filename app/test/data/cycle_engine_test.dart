import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/domain/cycle_engine.dart';

void main() {
  group('CycleEngine', () {
    test('targetDay = 31 and now = 2026-01-31 returns 2026-02-28 (NOT March 3)', () {
      final now = DateTime(2026, 1, 31);
      final next = CycleEngine.nextOccurrence(31, now);
      expect(next, equals(DateTime(2026, 2, 28)));
    });

    test('targetDay = 31 and now = 2026-03-31 returns 2026-04-30 (NOT May 1)', () {
      final now = DateTime(2026, 3, 31);
      final next = CycleEngine.nextOccurrence(31, now);
      expect(next, equals(DateTime(2026, 4, 30)));
    });

    test('targetDay = 31 on leap year (2024-01-31) returns 2024-02-29', () {
      final now = DateTime(2024, 1, 31);
      final next = CycleEngine.nextOccurrence(31, now);
      expect(next, equals(DateTime(2024, 2, 29)));
    });

    test('daysInMonth handles regular, leap year, and 30/31 day months', () {
      expect(CycleEngine.daysInMonth(2026, 1), equals(31));
      expect(CycleEngine.daysInMonth(2026, 2), equals(28));
      expect(CycleEngine.daysInMonth(2024, 2), equals(29)); // leap
      expect(CycleEngine.daysInMonth(2026, 4), equals(30));
      expect(CycleEngine.daysInMonth(2026, 12), equals(31));
    });

    test('clampDay clamps values exceeding max days or less than 1', () {
      expect(CycleEngine.clampDay(2026, 2, 31), equals(28));
      expect(CycleEngine.clampDay(2024, 2, 31), equals(29));
      expect(CycleEngine.clampDay(2026, 4, 31), equals(30));
      expect(CycleEngine.clampDay(2026, 1, 15), equals(15));
      expect(CycleEngine.clampDay(2026, 1, 0), equals(1));
    });

    test('nextOccurrence returns occurrence in current month if still upcoming', () {
      final now = DateTime(2026, 5, 10);
      final next = CycleEngine.nextOccurrence(20, now);
      expect(next, equals(DateTime(2026, 5, 20)));
    });

    test('nextOccurrence rolls year over from December to January', () {
      final now = DateTime(2026, 12, 25);
      final next = CycleEngine.nextOccurrence(15, now);
      expect(next, equals(DateTime(2027, 1, 15)));
    });
  });
}
