import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

CardProduct _cashbackCard({
  required String id,
  required double rate,
  bool upiLinkable = true,
  CardNetwork network = CardNetwork.rupay,
  List<CapRule> caps = const [],
  ForexRule? forex,
  FuelSurchargeRule? fuel,
}) {
  final ruleId = '$id-rule';
  return CardProduct(
    id: id,
    name: id,
    network: network,
    isUpiLinkable: upiLinkable,
    rewardRules: [
      RewardRule(id: ruleId, unit: RewardUnit.cashbackPercent, rate: rate),
    ],
    capRules: caps,
    forexRule: forex,
    fuelRule: fuel,
  );
}

void main() {
  final engine = RecommendationEngine();

  group('UA-2.2.1 RuPay/UPI exclusion gate', () {
    test('a non-RuPay-linkable card is excluded in a UPI-QR context, never dropped', () {
      final card = _cashbackCard(id: 'visa-card', rate: 5, upiLinkable: false);
      final ctx = RecommendationContext(
        amount: Money.fromRupees(500),
        rail: TxnRail.upiQr,
      );

      final results = engine.rank(ctx, [CardSnapshot(product: card)]);

      expect(results, hasLength(1));
      expect(results.first.isExcluded, isTrue);
      expect(results.first.exclusionReason, contains('UPI'));
    });

    test('the same card is eligible on a swipe rail', () {
      final card = _cashbackCard(id: 'visa-card', rate: 5, upiLinkable: false);
      final ctx = RecommendationContext(
        amount: Money.fromRupees(500),
        rail: TxnRail.swipe,
      );

      final results = engine.rank(ctx, [CardSnapshot(product: card)]);

      expect(results.first.isExcluded, isFalse);
      expect(results.first.expectedValue, Money.fromRupees(25)); // 5% of 500
    });

    test('P2P transfers exclude every card with an explicit reason', () {
      final card = _cashbackCard(id: 'any-card', rate: 5);
      final ctx = RecommendationContext(
        amount: Money.fromRupees(500),
        rail: TxnRail.upiQr,
        isP2P: true,
      );

      final results = engine.rank(ctx, [CardSnapshot(product: card)]);
      expect(results.first.exclusionReason, contains('personal transfers'));
    });
  });

  group('UA-2.2.3 cap blending — boundary and 1 paisa either side', () {
    test('spend fully within cap headroom uses the base rate only', () {
      final capRule = CapRule(
        id: 'cap1',
        rewardRuleId: 'card-rule',
        label: '5% groceries cap',
        capValue: Money.fromRupees(3000),
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'card-rule', unit: RewardUnit.cashbackPercent, rate: 5),
        ],
        capRules: [capRule],
      );
      final snapshot = CardSnapshot(
        product: card,
        capRemaining: {'cap1': Money.fromRupees(2999.99)},
      );
      final ctx = RecommendationContext(
        amount: Money.fromRupees(2999.99),
        rail: TxnRail.swipe,
      );

      final result = engine.rank(ctx, [snapshot]).first;
      // Fully within headroom: exact 5% of the spend.
      expect(result.expectedValue, Money.fromRupees(2999.99) * 0.05);
    });

    test('spend crossing the cap by exactly 1 paisa blends pre/post rates', () {
      final capRule = CapRule(
        id: 'cap1',
        rewardRuleId: 'card-rule',
        label: '5% groceries cap',
        capValue: Money.fromRupees(3000),
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'card-rule', unit: RewardUnit.cashbackPercent, rate: 5),
        ],
        capRules: [capRule],
      );
      final remaining = Money.fromPaise(100); // ₹1 of headroom
      final snapshot = CardSnapshot(product: card, capRemaining: {'cap1': remaining});
      final ctx = RecommendationContext(
        amount: Money.fromPaise(101), // ₹1.01 — crosses by exactly 1 paisa
        rail: TxnRail.swipe,
      );

      final result = engine.rank(ctx, [snapshot]).first;
      final expectedPreValue = remaining * 0.05; // ₹1 at 5%
      final expectedPostValue = Money.fromPaise(1) * 0.01; // 1 paisa at 1%
      expect(result.expectedValue, expectedPreValue + expectedPostValue);
    });

    test('cap already exhausted applies the post-cap rate to the full amount', () {
      final capRule = CapRule(
        id: 'cap1',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(3000),
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'card-rule', unit: RewardUnit.cashbackPercent, rate: 5),
        ],
        capRules: [capRule],
      );
      final snapshot = CardSnapshot(product: card, capRemaining: {'cap1': const Money.zero()});
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);

      final result = engine.rank(ctx, [snapshot]).first;
      expect(result.expectedValue, Money.fromRupees(1000) * 0.01);
    });
  });

  group('UA-2.2.5 travel mode forex markup', () {
    test('subtracts markup including GST from the reward value', () {
      final card = _cashbackCard(
        id: 'travel-card',
        rate: 5,
        forex: const ForexRule(markupPercent: 2, gstOnMarkup: true),
      );
      final ctx = RecommendationContext(
        amount: Money.fromRupees(1000),
        rail: TxnRail.swipe,
        travelMode: true,
      );

      final result = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      final reward = Money.fromRupees(1000) * 0.05; // ₹50
      final markup = Money.fromRupees(1000) * (0.02 * 1.18); // 2% + 18% GST on it
      expect(result.expectedValue, reward - markup);
      expect(result.reasonLines.any((l) => l.contains('forex markup')), isTrue);
    });
  });

  group('UA-2.2.6 manual override', () {
    test('an overridden card is forced to the top even if its value is lower', () {
      final winner = _cashbackCard(id: 'high-rate', rate: 10);
      final overridden = _cashbackCard(id: 'low-rate', rate: 1);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);

      final results = engine.rank(ctx, [
        CardSnapshot(product: winner),
        CardSnapshot(product: overridden, forcedOverrideCardId: 'low-rate'),
      ]);

      expect(results.first.card.id, 'low-rate');
      expect(results.first.isOverride, isTrue);
    });
  });

  group('UA-2.2.8 deterministic tie-break', () {
    test('equal expected value breaks the tie by confirmed confidence, then card id', () {
      final cardA = _cashbackCard(id: 'card-a', rate: 5);
      final cardB = _cashbackCard(id: 'card-b', rate: 5);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);

      final results = engine.rank(ctx, [
        CardSnapshot(product: cardB),
        CardSnapshot(product: cardA),
      ]);

      // Same confidence (both estimated) and same value -> stable by card id.
      expect(results.map((r) => r.card.id).toList(), ['card-a', 'card-b']);
    });

    test('ranking is total: every input card appears exactly once in the output', () {
      final cards = List.generate(15, (i) => _cashbackCard(id: 'card-$i', rate: (i % 5) + 1.0));
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);

      final results = engine.rank(ctx, cards.map((c) => CardSnapshot(product: c)).toList());

      expect(results, hasLength(15));
      expect(results.map((r) => r.card.id).toSet(), cards.map((c) => c.id).toSet());
    });
  });

  group('UA-2.3 explanation generator reconciliation', () {
    test('a simple base-rate reason line names the exact rate shown', () {
      final card = _cashbackCard(id: 'card', rate: 5);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);

      final result = engine.rank(ctx, [CardSnapshot(product: card)]).first;

      expect(result.reasonLines, isNotEmpty);
      expect(result.reasonLines.first, contains('5.0%'));
      expect(result.expectedValue, Money.fromRupees(50));
    });

    test('excluded cards carry no reason lines — the exclusion reason is the whole story', () {
      final card = _cashbackCard(id: 'card', rate: 5, upiLinkable: false);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.upiQr);

      final result = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(result.reasonLines, isEmpty);
      expect(result.exclusionReason, isNotNull);
    });
  });

  group('No applicable rule', () {
    test('a card with no matching reward rule is excluded, not zero-valued silently', () {
      final card = CardProduct(id: 'bare', name: 'bare', network: CardNetwork.rupay);
      final ctx = RecommendationContext(amount: Money.fromRupees(100), rail: TxnRail.swipe);

      final result = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(result.isExcluded, isTrue);
    });
  });
}
