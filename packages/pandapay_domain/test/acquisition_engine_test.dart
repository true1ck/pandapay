import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

CardProduct _card({
  required String id,
  double rate = 5,
  String? categoryId,
  Money? annualFee,
  List<CapRule> caps = const [],
  List<MilestoneRule> milestones = const [],
  List<FeeWaiverRule> feeWaivers = const [],
}) {
  return CardProduct(
    id: id,
    name: id,
    network: CardNetwork.rupay,
    isUpiLinkable: true,
    rewardRules: [
      RewardRule(id: '$id-rule', categoryId: categoryId, unit: RewardUnit.cashbackPercent, rate: rate),
    ],
    capRules: caps,
    milestoneRules: milestones,
    feeWaiverRules: feeWaivers,
    annualFeeInr: annualFee,
  );
}

void main() {
  final recommender = CardAcquisitionRecommender();

  group('basic ranking', () {
    test('a candidate that beats every owned card on every category ranks with positive uplift', () {
      final owned = _card(id: 'owned', rate: 1);
      final candidate = _card(id: 'candidate', rate: 5);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(100000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: [owned], spendProfile: profile);

      expect(results, hasLength(1));
      expect(results.first.card.id, 'candidate');
      expect(results.first.uplift, Money.fromRupees(4000)); // (5%-1%) of 100000
      expect(results.first.isWorthwhile, isTrue);
    });

    test('a candidate that never beats an owned card in any category gets a negative uplift equal to its fee', () {
      final owned = _card(id: 'owned', rate: 10);
      final candidate = _card(id: 'candidate', rate: 1, annualFee: Money.fromRupees(500));
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(50000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: [owned], spendProfile: profile);

      expect(results.first.uplift, Money.fromRupees(-500));
      expect(results.first.isWorthwhile, isFalse);
      expect(results.first.projectedAnnualValue, const Money.zero());
    });

    test('an already-owned card is never returned as a candidate', () {
      final owned = _card(id: 'shared', rate: 5);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(1000)});

      final results = recommender.rank(candidates: [owned], ownedCards: [owned], spendProfile: profile);

      expect(results, isEmpty);
    });

    test('results are sorted by uplift, highest first', () {
      final owned = _card(id: 'owned', rate: 2);
      final low = _card(id: 'low', rate: 3);
      final high = _card(id: 'high', rate: 8);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(10000)});

      final results =
          recommender.rank(candidates: [low, high], ownedCards: [owned], spendProfile: profile);

      expect(results.map((r) => r.card.id).toList(), ['high', 'low']);
    });

    test('zero spend in every category yields zero uplift for every candidate, not an error', () {
      final candidate = _card(id: 'candidate', rate: 5, annualFee: const Money.zero());
      final profile = SpendProfile(annualSpendByCategory: {'dining': const Money.zero()});

      final results = recommender.rank(candidates: [candidate], ownedCards: const [], spendProfile: profile);

      expect(results.first.uplift, const Money.zero());
    });
  });

  group('portfolio math — a candidate only wins the categories it actually beats the owned lineup on', () {
    test('a fuel-specialist candidate only takes fuel spend, leaving dining to the owned card', () {
      final owned = _card(id: 'owned-generalist', rate: 3); // wins everywhere by default
      final fuelSpecialist = _card(id: 'fuel-card', rate: 10, categoryId: 'fuel');
      final profile = SpendProfile(annualSpendByCategory: {
        'fuel': Money.fromRupees(20000),
        'dining': Money.fromRupees(20000),
      });

      final results = recommender.rank(
        candidates: [fuelSpecialist],
        ownedCards: [owned],
        spendProfile: profile,
      );

      final r = results.first;
      // Only wins fuel (10% > 3%); dining stays with the owned generalist (3% > 0%, since
      // fuel-card has no base rate for non-fuel categories).
      expect(r.valueByCategory.keys.toSet(), {'fuel'});
      expect(r.projectedAnnualValue, Money.fromRupees(2000)); // 10% of 20000
      // Uplift is JUST the fuel improvement (10%-3% of 20000 = 1400), not the
      // candidate's full standalone earning — proving this is a portfolio
      // comparison, not "value of candidate alone".
      expect(r.uplift, Money.fromRupees(1400));
    });
  });

  group('annualized caps', () {
    test('a monthly cap is scaled by 12 before being compared against the annual spend', () {
      final cap = CapRule(
        id: 'cap',
        rewardRuleId: 'candidate-rule',
        label: 'monthly cap',
        capValue: Money.fromRupees(1000), // -> 12,000/year headroom before blending
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final candidate = _card(id: 'candidate', rate: 5, caps: [cap]);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(20000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: const [], spendProfile: profile);

      // 12,000 at 5% + 8,000 at 1% (post-cap) = 600 + 80 = 680
      expect(results.first.projectedAnnualValue, Money.fromRupees(680));
    });
  });

  group('milestones', () {
    test('a milestone the projected annual spend clears adds its full reward value once', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend 1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(2000),
      );
      final candidate = _card(id: 'candidate', rate: 1, milestones: [milestone]);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(150000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: const [], spendProfile: profile);

      // 1% of 150000 = 1500, plus the milestone's flat 2000 = 3500
      expect(results.first.projectedAnnualValue, Money.fromRupees(3500));
    });

    test('a repeatable milestone credits once per full multiple of its threshold', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Every 50k',
        thresholdSpend: Money.fromRupees(50000),
        rewardValue: Money.fromRupees(500),
        isRepeatable: true,
      );
      final candidate = _card(id: 'candidate', rate: 0, milestones: [milestone]);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(170000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: const [], spendProfile: profile);

      // floor(170000/50000) = 3 -> 1500
      expect(results.first.projectedAnnualValue, Money.fromRupees(1500));
    });
  });

  group('fee waivers', () {
    test('a candidate whose attributed spend clears its waiver threshold pays no net fee', () {
      final waiver = FeeWaiverRule(
        id: 'w',
        thresholdSpend: Money.fromRupees(100000),
        period: CapPeriod.annual,
        waivesFee: Money.fromRupees(999),
      );
      final candidate = _card(id: 'candidate', rate: 5, annualFee: Money.fromRupees(999), feeWaivers: [waiver]);
      final profile = SpendProfile(annualSpendByCategory: {null: Money.fromRupees(150000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: const [], spendProfile: profile);

      expect(results.first.annualFeeNet, const Money.zero());
    });

    test('spend in a category the waiver excludes does not count toward clearing it', () {
      final waiver = FeeWaiverRule(
        id: 'w',
        thresholdSpend: Money.fromRupees(100000),
        period: CapPeriod.annual,
        waivesFee: Money.fromRupees(999),
        excludedCategoryIds: const ['rent'],
      );
      final candidate = _card(id: 'candidate', rate: 5, annualFee: Money.fromRupees(999), feeWaivers: [waiver]);
      // Only rent spend, which the waiver excludes -> should NOT clear the threshold
      // even though the raw total (150000) would.
      final profile = SpendProfile(annualSpendByCategory: {'rent': Money.fromRupees(150000)});

      final results = recommender.rank(candidates: [candidate], ownedCards: const [], spendProfile: profile);

      expect(results.first.annualFeeNet, Money.fromRupees(999));
    });
  });
}
