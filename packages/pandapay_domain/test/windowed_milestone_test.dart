import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D32b: the engine does not credit a windowed (welcome) milestone
/// (`window_days` set) in Phase 1. Once the window has closed the server
/// returns no milestone row, so progress reads 0 and the bonus was pro-rated
/// in for ever: Amex Platinum Charge showed ₹36,000 of milestone on ₹30,000 of
/// spend against a true reward of ₹187.50. Phase 2 adds the window maths.
const _snapshotDir = '../../db/fixtures/catalogue_v2_cards';

Map<String, dynamic> _fixture(String slug) =>
    (jsonDecode(File('$_snapshotDir/$slug.json').readAsStringSync())
            as Map<String, dynamic>)['card']
        as Map<String, dynamic>;

Recommendation _rank(CardProduct card, double amount) => const RecommendationEngine()
    .rank(
      RecommendationContext(
        amount: Money.fromRupees(amount),
        rail: TxnRail.swipe,
        now: DateTime(2026, 11, 6),
      ),
      [CardSnapshot(product: card)],
    )
    .single;

MilestoneRule _milestone({int? windowDays}) => MilestoneRule(
  id: 'm',
  label: 'Spend ₹50,000',
  thresholdSpend: Money.fromRupees(50000),
  rewardValue: Money.fromRupees(60000),
  windowDays: windowDays,
);

// A matching rule, so the v1 path that credits milestones is the one taken
// (a card with no rule at all falls back to its base rate before it).
CardProduct _v1Card(MilestoneRule milestone) => CardProduct(
  id: 'v1',
  name: 'v1',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: const [
    RewardRule(id: 'r', unit: RewardUnit.cashbackPercent, rate: 1),
  ],
  milestoneRules: [milestone],
);

CardProduct _v2Card(MilestoneRule milestone) => CardProduct(
  id: 'v2',
  name: 'v2',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  accrualRounding: AccrualRounding.floor,
  milestoneRules: [milestone],
);

void main() {
  group('Amex Platinum Charge (v2 fixture)', () {
    final card = CardProductJson.fromJson(
      _fixture('american-express-platinum-charge-card-india'),
    );

    test('₹30,000 of spend earns its true ₹187.50, not a pro-rated welcome '
        'gift', () {
      final rec = _rank(card, 30000);
      expect(card.isV2Shaped, isTrue);
      expect(rec.breakdown?.milestoneBonus, const Money.zero());
      expect(rec.expectedValue, Money.fromRupees(187.5));
      expect(rec.reasonLines.where((l) => l.contains('milestone')), isEmpty);
    });

    // Platinum Charge's welcome/renewal values are "up to" figures and were set
    // to null (D13), so the loaded card no longer carries a windowed milestone;
    // the synthetic cases below still prove windowed milestones are skipped.
    test('the loaded card no longer credits any welcome milestone', () {
      expect(card.milestoneRules.where((m) => m.windowDays != null), isEmpty);
    });
  });

  group('v2-shaped card', () {
    test('a windowed milestone is not credited, however much of it the spend '
        'covers', () {
      final rec = _rank(_v2Card(_milestone(windowDays: 60)), 30000);
      expect(rec.breakdown?.milestoneBonus, const Money.zero());
      expect(rec.expectedValue, Money.fromRupees(300)); // 1% of ₹30,000
    });

    test('the same milestone without a window is still credited '
        '(unchanged)', () {
      final rec = _rank(_v2Card(_milestone()), 30000);
      // 60% of ₹50,000 closed: ₹60,000 x 0.6.
      expect(rec.breakdown?.milestoneBonus, Money.fromRupees(36000));
    });
  });

  group('v1-shaped card', () {
    test('a windowed milestone is not credited either', () {
      final card = _v1Card(_milestone(windowDays: 90));
      expect(card.isV2Shaped, isFalse);
      final rec = _rank(card, 30000);
      expect(rec.expectedValue, Money.fromRupees(300));
      expect(rec.reasonLines.where((l) => l.contains('milestone')), isEmpty);
    });

    test('a milestone without a window is still credited (unchanged)', () {
      final rec = _rank(_v1Card(_milestone()), 30000);
      // ₹300 base + ₹60,000 x 0.6 of the milestone.
      expect(rec.expectedValue, Money.fromRupees(36300));
      expect(
        rec.reasonLines.any((l) => l.contains('materially advances')),
        isTrue,
      );
    });
  });
}
