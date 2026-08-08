import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Chunk 36 / E4 Milestones — `evaluateMilestoneChase()`'s "chasing beats
/// base rate" flag, new this pass with no prior test coverage.
void main() {
  group('evaluateMilestoneChase', () {
    test('a marginal rate above the base rate is flagged as worth chasing', () {
      // Reward 1000 over remaining spend 10000 -> marginal 0.10/rupee, well
      // above a 2% (0.02) base cashback rate.
      final chase = evaluateMilestoneChase(
        rewardValue: Money.fromRupees(1000),
        remainingSpend: Money.fromRupees(10000),
        baseRatePerRupee: 0.02,
      );
      expect(chase.marginalRatePerRupee, closeTo(0.10, 0.0001));
      expect(chase.beatsBaseRate, isTrue);
    });

    test('a marginal rate below the base rate is not flagged', () {
      // Reward 100 over remaining spend 10000 -> marginal 0.01/rupee, below
      // a 2% base rate.
      final chase = evaluateMilestoneChase(
        rewardValue: Money.fromRupees(100),
        remainingSpend: Money.fromRupees(10000),
        baseRatePerRupee: 0.02,
      );
      expect(chase.marginalRatePerRupee, closeTo(0.01, 0.0001));
      expect(chase.beatsBaseRate, isFalse);
    });

    test('a marginal rate exactly equal to the base rate does not count as "beats"', () {
      final chase = evaluateMilestoneChase(
        rewardValue: Money.fromRupees(200),
        remainingSpend: Money.fromRupees(10000),
        baseRatePerRupee: 0.02, // 200/10000 == 0.02 exactly
      );
      expect(chase.beatsBaseRate, isFalse);
    });

    test('zero remaining spend returns a zero marginal rate rather than dividing by zero', () {
      final chase = evaluateMilestoneChase(
        rewardValue: Money.fromRupees(500),
        remainingSpend: const Money.zero(),
        baseRatePerRupee: 0.02,
      );
      expect(chase.marginalRatePerRupee, 0);
      expect(chase.beatsBaseRate, isFalse);
    });

    test('a zero base rate means any positive marginal reward beats it', () {
      final chase = evaluateMilestoneChase(
        rewardValue: Money.fromRupees(10),
        remainingSpend: Money.fromRupees(1000),
        baseRatePerRupee: 0,
      );
      expect(chase.beatsBaseRate, isTrue);
    });
  });
}
