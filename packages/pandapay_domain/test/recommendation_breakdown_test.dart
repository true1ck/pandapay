import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Design 09 "Why this card?" reads [RecommendationBreakdown] instead of
/// keyword-matching [Recommendation.reasonLines]. These lock in the
/// distinctions that matter on that screen — particularly the ones where
/// null and zero mean different things.

CardProduct _card({
  required String id,
  required double rate,
  RewardUnit unit = RewardUnit.cashbackPercent,
  double pointValueInr = 0,
  String? merchantPattern,
  List<CapRule> caps = const [],
  ForexRule? forex,
  FuelSurchargeRule? fuel,
}) => CardProduct(
  id: id,
  name: id,
  network: CardNetwork.rupay,
  isUpiLinkable: true,
  pointValueInr: pointValueInr,
  rewardRules: [
    RewardRule(id: '$id-rule', unit: unit, rate: rate, merchantPattern: merchantPattern),
  ],
  capRules: caps,
  forexRule: forex,
  fuelRule: fuel,
);

void main() {
  final engine = RecommendationEngine();
  final ctx = RecommendationContext(amount: Money.fromRupees(2500), rail: TxnRail.swipe);

  RecommendationBreakdown breakdownFor(CardProduct card, {CardSnapshot? snapshot}) {
    final result = engine.rank(ctx, [snapshot ?? CardSnapshot(product: card)]).first;
    return result.breakdown!;
  }

  test('reports the base rate and what it pays on this amount', () {
    final b = breakdownFor(_card(id: 'c', rate: 5));
    expect(b.baseRatePerRupee, closeTo(0.05, 1e-9));
    expect(b.baseValue, Money.fromRupees(125));
  });

  test('a card with no cap reports null headroom, not zero', () {
    // Design 09 renders null as "None" and zero as "₹0 free" — a card with
    // no cap at all must not read as one whose cap is exhausted.
    final b = breakdownFor(_card(id: 'c', rate: 5));
    expect(b.capHeadroom, isNull);
    expect(b.capNote, isNull);
  });

  test('a spend cap reports its remaining headroom in rupees', () {
    final card = _card(
      id: 'c',
      rate: 5,
      caps: [
        CapRule(
          id: 'cap',
          label: 'Monthly cap',
          rewardRuleId: 'c-rule',
          capValue: Money.fromRupees(10000),
          period: CapPeriod.calendarMonth,
          measure: CapMeasure.spendAmount,
        ),
      ],
    );
    final b = breakdownFor(
      card,
      snapshot: CardSnapshot(
        product: card,
        capRemaining: {'cap': Money.fromRupees(4000)},
      ),
    );
    expect(b.capHeadroom, Money.fromRupees(4000));
  });

  test('an exhausted spend cap reports zero headroom and says so', () {
    final card = _card(
      id: 'c',
      rate: 5,
      caps: [
        CapRule(
          id: 'cap',
          label: 'Monthly cap',
          rewardRuleId: 'c-rule',
          capValue: Money.fromRupees(10000),
          period: CapPeriod.calendarMonth,
          measure: CapMeasure.spendAmount,
        ),
      ],
    );
    final b = breakdownFor(
      card,
      snapshot: CardSnapshot(product: card, capRemaining: {'cap': const Money.zero()}),
    );
    expect(b.capHeadroom, const Money.zero());
    expect(b.capNote, 'Cap reached');
  });

  test('a reward-value cap uses the note, not the rupee headroom row', () {
    // "₹1,000 of cashback left" is not spend headroom; rendering it in the
    // "₹N free" row would tell the user they can spend ₹1,000 more at 5%.
    final card = _card(
      id: 'c',
      rate: 5,
      caps: [
        CapRule(
          id: 'cap',
          label: 'Monthly cap',
          rewardRuleId: 'c-rule',
          capValue: Money.fromRupees(1000),
          period: CapPeriod.calendarMonth,
          measure: CapMeasure.rewardValue,
        ),
      ],
    );
    final b = breakdownFor(
      card,
      snapshot: CardSnapshot(
        product: card,
        capRemaining: {'cap': Money.fromRupees(600)},
      ),
    );
    expect(b.capHeadroom, isNull);
    expect(b.capNote, contains('reward value'));
  });

  test('points value is reported for points rules and null for cashback', () {
    final points = breakdownFor(
      _card(id: 'p', rate: 2, unit: RewardUnit.pointsPer100, pointValueInr: 0.25),
    );
    expect(points.pointValueInr, 0.25);

    final cashback = breakdownFor(_card(id: 'c', rate: 5));
    expect(cashback.pointValueInr, isNull, reason: 'a ₹/point row on a cashback card is noise');
  });

  test('merchant restriction is carried through, null when unrestricted', () {
    expect(breakdownFor(_card(id: 'c', rate: 5)).merchantRestriction, isNull);
    expect(
      breakdownFor(_card(id: 'c', rate: 5, merchantPattern: 'AMAZON')).merchantRestriction,
      'AMAZON',
    );
  });

  test('adjustments are zero when they did not apply', () {
    final b = breakdownFor(_card(id: 'c', rate: 5));
    expect(b.forexCost, const Money.zero());
    expect(b.fuelWaiver, const Money.zero());
    expect(b.milestoneBonus, const Money.zero());
    expect(b.hasAdjustments, isFalse);
  });

  test('forex markup is recorded separately from the final value', () {
    final card = _card(id: 'c', rate: 5, forex: const ForexRule(markupPercent: 3.5));
    final result = engine
        .rank(
          RecommendationContext(amount: Money.fromRupees(2500), rail: TxnRail.swipe, travelMode: true),
          [CardSnapshot(product: card)],
        )
        .first;
    final b = result.breakdown!;
    expect(b.forexCost.isZero, isFalse);
    expect(b.hasAdjustments, isTrue);
    // The breakdown's own arithmetic has to reconcile to the headline.
    expect(b.baseValue - b.forexCost, result.expectedValue);
  });

  test('an excluded card carries no breakdown to show', () {
    final card = _card(id: 'visa', rate: 5);
    final excluded = engine
        .rank(
          RecommendationContext(amount: Money.fromRupees(2500), rail: TxnRail.upiQr),
          [
            CardSnapshot(
              product: CardProduct(
                id: 'visa',
                name: 'visa',
                network: CardNetwork.visa,
                isUpiLinkable: false,
                rewardRules: card.rewardRules,
              ),
            ),
          ],
        )
        .first;
    expect(excluded.isExcluded, isTrue);
    expect(excluded.breakdown, isNull);
  });
}
