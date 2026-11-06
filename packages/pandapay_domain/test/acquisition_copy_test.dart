import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D35d: the acquisition recommender projects each card through a copy
/// (`_withoutMilestones`). The copy
///  * dropped the card's `excludedCategoryIds` (since the released app), so
///    Discover credited a card for spend it excludes at card level (H2: an
///    over-statement), and
///  * de-duplicated the rules and caps of a v2-shaped card, which D15a forbids:
///    merging rows can orphan a cap's `targets` or `parent_cap_id`.
Money _projected(CardProduct candidate, Map<String?, double> spend) {
  const recommender = CardAcquisitionRecommender();
  final results = recommender.rank(
    candidates: [candidate],
    ownedCards: const [],
    spendProfile: SpendProfile(
      annualSpendByCategory: {
        for (final e in spend.entries) e.key: Money.fromRupees(e.value),
      },
    ),
  );
  return results.single.projectedAnnualValue;
}

void main() {
  group('card-level excluded categories', () {
    CardProduct card({List<String> excluded = const []}) => CardProduct(
      id: 'c',
      name: 'c',
      network: CardNetwork.visa,
      isUpiLinkable: true,
      baseRewardUnit: RewardUnit.cashbackPercent,
      baseRewardRate: 5,
      excludedCategoryIds: excluded,
    );

    test('a card with no exclusion is credited everywhere (unchanged)', () {
      expect(_projected(card(), {'fuel': 100000}), Money.fromRupees(5000));
    });

    test('an excluded category earns nothing in Discover', () {
      expect(
        _projected(card(excluded: ['fuel']), {'fuel': 100000}),
        const Money.zero(),
      );
    });

    test('other categories are still credited', () {
      expect(
        _projected(card(excluded: ['fuel']), {
          'fuel': 100000,
          'dining': 20000,
        }),
        Money.fromRupees(1000), // 5% of the dining spend only
      );
    });
  });

  group('a v2-shaped card keeps its rules and caps as they are (D15a)', () {
    // Two rules identical in every identity field (so the v1 de-dup would
    // merge them) with different ids; the cap targets the one the engine
    // picks (the id that sorts first) and is listed second. De-duplicating
    // keeps the first listed rule ('r_b'), orphans the cap, and the cap stops
    // applying.
    CardProduct v2Card() => CardProduct(
      id: 'v2',
      name: 'v2',
      network: CardNetwork.visa,
      isUpiLinkable: true,
      baseRewardUnit: RewardUnit.cashbackPercent,
      baseRewardRate: 1,
      cashbackRounding: CashbackRounding.paise,
      rewardRules: const [
        RewardRule(
          id: 'r_b',
          unit: RewardUnit.cashbackPercent,
          rate: 10,
          priority: 10,
        ),
        RewardRule(
          id: 'r_a',
          unit: RewardUnit.cashbackPercent,
          rate: 10,
          priority: 10,
        ),
      ],
      capRules: [
        CapRule(
          id: 'cap',
          label: 'Cashback cap',
          capValue: Money.fromRupees(100),
          measure: CapMeasure.rewardValue,
          period: CapPeriod.calendarMonth,
          capKind: CapKind.totalCashback,
          capAmount: 100,
          targets: const ['r_a'],
        ),
      ],
    );

    test('the cap still binds: ₹10,000 at 10% is capped at ₹100, not ₹1,000',
        () {
      expect(v2Card().isV2Shaped, isTrue);
      expect(_projected(v2Card(), {null: 10000}), Money.fromRupees(100));
    });

    test('a v1-shaped card is still de-duplicated (unchanged)', () {
      // The same two rules without any v2 field collapse to one: the cap
      // (keyed by id, v1) is unaffected and the card projects as before.
      final v1 = CardProduct(
        id: 'v1',
        name: 'v1',
        network: CardNetwork.visa,
        isUpiLinkable: true,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: const [
          RewardRule(id: 'r_b', unit: RewardUnit.cashbackPercent, rate: 10),
          RewardRule(id: 'r_a', unit: RewardUnit.cashbackPercent, rate: 10),
        ],
      );
      expect(v1.isV2Shaped, isFalse);
      expect(_projected(v1, {null: 10000}), Money.fromRupees(1000));
    });
  });
}
