import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D35a: every milestone loop skips a windowed (welcome) milestone,
/// the acquisition recommender's too. Amex Platinum Charge on a ₹60,000-a-year
/// profile showed ₹60,375 in Discover instead of ₹375: its ₹60,000 welcome
/// milestone (₹50,000 within 60 days) was credited against a whole year of
/// projected spend.
const _snapshotDir = '../../db/fixtures/catalogue_v2_cards';

CardProduct _fixture(String slug) => CardProductJson.fromJson(
  (jsonDecode(File('$_snapshotDir/$slug.json').readAsStringSync())
          as Map<String, dynamic>)['card']
      as Map<String, dynamic>,
);

Money _projected(CardProduct candidate, double annualSpend) {
  const recommender = CardAcquisitionRecommender();
  final results = recommender.rank(
    candidates: [candidate],
    ownedCards: const [],
    spendProfile: SpendProfile(
      annualSpendByCategory: {null: Money.fromRupees(annualSpend)},
    ),
  );
  return results.single.projectedAnnualValue;
}

CardProduct _cashback({List<MilestoneRule> milestones = const []}) =>
    CardProduct(
      id: 'c',
      name: 'c',
      network: CardNetwork.visa,
      isUpiLinkable: true,
      baseRewardUnit: RewardUnit.cashbackPercent,
      baseRewardRate: 1,
      milestoneRules: milestones,
    );

void main() {
  group('Amex Platinum Charge (fixture)', () {
    final amex = _fixture('american-express-platinum-charge-card-india');

    test('the fixture carries a windowed welcome milestone', () {
      expect(amex.milestoneRules.any((m) => m.windowDays != null), isTrue);
    });

    test('₹60,000 a year projects its true ₹375, not ₹60,375', () {
      final withMilestones = _projected(amex, 60000);
      // The same card with its milestones removed is the reference.
      final without = _projected(
        CardProduct(
          id: amex.id,
          name: amex.name,
          network: amex.network,
          isUpiLinkable: amex.isUpiLinkable,
          pointValueInr: amex.pointValueInr,
          baseRewardUnit: amex.baseRewardUnit,
          baseRewardRate: amex.baseRewardRate,
          rewardRules: amex.rewardRules,
          capRules: amex.capRules,
          excludedCategoryIds: amex.excludedCategoryIds,
          accrualRounding: amex.accrualRounding,
          cashbackRounding: amex.cashbackRounding,
          wireV2Shaped: amex.wireV2Shaped,
        ),
        60000,
      );
      expect(withMilestones, without);
      expect(withMilestones, Money.fromRupees(375));
    });
  });

  group('windowed vs unwindowed milestones', () {
    MilestoneRule milestone({int? windowDays, bool repeatable = false}) =>
        MilestoneRule(
          id: 'm',
          label: 'Spend ₹50,000',
          thresholdSpend: Money.fromRupees(50000),
          rewardValue: Money.fromRupees(2000),
          isRepeatable: repeatable,
          windowDays: windowDays,
        );

    test('a windowed milestone is not credited, whatever the spend', () {
      final base = _projected(_cashback(), 120000);
      expect(
        _projected(_cashback(milestones: [milestone(windowDays: 60)]), 120000),
        base,
      );
      // Repeatable too.
      expect(
        _projected(
          _cashback(milestones: [milestone(windowDays: 60, repeatable: true)]),
          120000,
        ),
        base,
      );
    });

    test('an unwindowed milestone is still credited (unchanged)', () {
      final base = _projected(_cashback(), 120000);
      expect(
        _projected(_cashback(milestones: [milestone()]), 120000),
        base + Money.fromRupees(2000),
      );
      expect(
        _projected(_cashback(milestones: [milestone(repeatable: true)]), 120000),
        base + Money.fromRupees(4000), // twice ₹50,000 fits in ₹1,20,000
      );
    });
  });
}
