import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Chunk 36 (implementation-plan-group-e-f-g.md §1) — urgency.dart's shared
/// sort helper, feeding E1's nearest-deadline-first ordering across every
/// tracker kind. No test file previously covered this new file.
void main() {
  group('UrgencyScore', () {
    test('a higher ratioConsumed sorts before a lower one when days are equal', () {
      final urgent = UrgencyScore(ratioConsumed: 0.9, daysRemaining: 10);
      final lessUrgent = UrgencyScore(ratioConsumed: 0.2, daysRemaining: 10);
      final list = [lessUrgent, urgent]..sort();
      expect(list.first, same(urgent));
    });

    test('fewer daysRemaining sorts before more days when ratio is equal', () {
      final soon = UrgencyScore(ratioConsumed: 0.5, daysRemaining: 2);
      final later = UrgencyScore(ratioConsumed: 0.5, daysRemaining: 300);
      final list = [later, soon]..sort();
      expect(list.first, same(soon));
    });

    test('an item with neither signal sorts last (least urgent), not excluded', () {
      final withRatio = UrgencyScore(ratioConsumed: 0.1, daysRemaining: 3650);
      final withDays = UrgencyScore(ratioConsumed: null, daysRemaining: 5);
      final withNeither = UrgencyScore(ratioConsumed: null, daysRemaining: null);
      final list = [withNeither, withDays, withRatio]..sort();
      expect(list.last, same(withNeither));
    });

    test('ratioConsumed is clamped into 0..1 rather than let a stray value skew ordering', () {
      final overOne = UrgencyScore(ratioConsumed: 1.5, daysRemaining: 10);
      final atOne = UrgencyScore(ratioConsumed: 1.0, daysRemaining: 10);
      // Both clamp to the same effective urgency -> stable, no crash, no
      // paradoxical "more than fully consumed is more urgent than fully".
      expect(overOne.compareTo(atOne), 0);
    });

    test('a negative ratioConsumed is clamped up to 0', () {
      final negative = UrgencyScore(ratioConsumed: -0.5, daysRemaining: 10);
      final zero = UrgencyScore(ratioConsumed: 0.0, daysRemaining: 10);
      expect(negative.compareTo(zero), 0);
    });
  });

  group('daysUntil', () {
    test('counts whole days between two dates, ignoring time-of-day', () {
      final today = DateTime(2026, 3, 10, 23, 59);
      final target = DateTime(2026, 3, 15, 0, 1);
      expect(daysUntil(target, today), 5);
    });

    test('returns 0 for the same calendar day even with different times', () {
      final today = DateTime(2026, 3, 10, 8, 0);
      final target = DateTime(2026, 3, 10, 22, 0);
      expect(daysUntil(target, today), 0);
    });

    test('returns a negative number for a date already in the past', () {
      final today = DateTime(2026, 3, 10);
      final target = DateTime(2026, 3, 1);
      expect(daysUntil(target, today), -9);
    });
  });

  group('capRatio', () {
    test('returns the consumed fraction of the cap value', () {
      expect(capRatio(Money.fromRupees(300), Money.fromRupees(1000)), closeTo(0.3, 0.0001));
    });

    test('clamps above 1.0 when consumption exceeds the cap (over-limit case)', () {
      expect(capRatio(Money.fromRupees(1500), Money.fromRupees(1000)), 1.0);
    });

    test('returns 0 for a zero cap value rather than dividing by zero', () {
      expect(capRatio(Money.fromRupees(100), const Money.zero()), 0);
    });
  });
}
