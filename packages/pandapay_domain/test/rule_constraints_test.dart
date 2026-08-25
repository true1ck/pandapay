import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Coverage for the rule constraints the engine models but historically
/// never enforced: merchant pattern, rail, min/max transaction, catalogue
/// validity window, and category exclusions — plus post-cap rate
/// resolution, which used to collapse to ₹0.
///
/// Every case here is a real Indian-market card wording ("5% at Amazon
/// only", "5% on the first ₹5,000 per transaction", "no rewards on rent"),
/// not a synthetic edge case: the point of the predicate is that the
/// catalogue can be written the way issuers write their terms.

CardProduct _card({
  String id = 'c',
  List<RewardRule> rules = const [],
  List<CapRule> caps = const [],
  RewardUnit? baseUnit = RewardUnit.cashbackPercent,
  double? baseRate = 1,
  List<String> excludedCategories = const [],
  double pointValueInr = 0,
}) =>
    CardProduct(
      id: id,
      name: id,
      network: CardNetwork.visa,
      isUpiLinkable: true,
      pointValueInr: pointValueInr,
      baseRewardUnit: baseUnit,
      baseRewardRate: baseRate,
      excludedCategoryIds: excludedCategories,
      rewardRules: rules,
      capRules: caps,
    );

RewardRule _rule({
  String id = 'r',
  String? categoryId,
  String? merchantPattern,
  TxnRail? rail,
  double rate = 5,
  RewardUnit unit = RewardUnit.cashbackPercent,
  Money? minTxn,
  Money? maxTxn,
  List<String> excludedCategoryIds = const [],
  DateTime? effectiveFrom,
  DateTime? effectiveTo,
}) =>
    RewardRule(
      id: id,
      categoryId: categoryId,
      merchantPattern: merchantPattern,
      rail: rail,
      unit: unit,
      rate: rate,
      minTxn: minTxn,
      maxTxn: maxTxn,
      excludedCategoryIds: excludedCategoryIds,
      effectiveFrom: effectiveFrom,
      effectiveTo: effectiveTo,
    );

void main() {
  const engine = RecommendationEngine();

  Recommendation evaluate(CardProduct card, RecommendationContext ctx, {CardSnapshot? snapshot}) =>
      engine.rank(ctx, [snapshot ?? CardSnapshot(product: card)]).first;

  RecommendationContext ctx({
    double amount = 1000,
    String? categoryId,
    String? merchantName,
    TxnRail rail = TxnRail.swipe,
    DateTime? now,
  }) =>
      RecommendationContext(
        amount: Money.fromRupees(amount),
        categoryId: categoryId,
        merchantName: merchantName,
        rail: rail,
        now: now,
      );

  group('merchant restriction', () {
    final card = _card(rules: [_rule(merchantPattern: 'amazon', rate: 10)]);

    test('applies at the named merchant', () {
      final r = evaluate(card, ctx(merchantName: 'Amazon'));
      expect(r.expectedValue, Money.fromRupees(100)); // 10%
    });

    test('matches despite the formatting a bank SMS actually uses', () {
      // Real merchant strings arrive as 'AMAZON  PAY IND*ORD', never as the
      // catalogue's tidy 'amazon'.
      final r = evaluate(card, ctx(merchantName: 'AMAZON  PAY IND*ORD'));
      expect(r.expectedValue, Money.fromRupees(100));
    });

    test('falls through to the base rate at a different merchant', () {
      final r = evaluate(card, ctx(merchantName: 'Flipkart'));
      expect(r.expectedValue, Money.fromRupees(10)); // 1% base
    });

    test('falls through to the base rate when the merchant is unknown', () {
      // An unidentified merchant cannot satisfy an Amazon-only rule.
      // Promising 10% here is precisely the over-promise being guarded.
      final r = evaluate(card, ctx(merchantName: null));
      expect(r.expectedValue, Money.fromRupees(10));
    });
  });

  group('rail restriction', () {
    final card = _card(rules: [_rule(rail: TxnRail.swipe, rate: 10)]);

    test('applies on the named rail', () {
      expect(evaluate(card, ctx(rail: TxnRail.swipe)).expectedValue, Money.fromRupees(100));
    });

    test('does not apply on a different rail', () {
      expect(evaluate(card, ctx(rail: TxnRail.upiQr)).expectedValue, Money.fromRupees(10));
    });

    test('an unknown rail is treated as unverified, not as a mismatch', () {
      // Every SMS/email import lands with rail unknown; failing the match
      // there would under-report the earn rate on all imported spend.
      expect(evaluate(card, ctx(rail: TxnRail.unknown)).expectedValue, Money.fromRupees(100));
    });
  });

  group('minimum transaction', () {
    final card = _card(rules: [_rule(minTxn: Money.fromRupees(500), rate: 10)]);

    test('applies at exactly the floor', () {
      expect(evaluate(card, ctx(amount: 500)).expectedValue, Money.fromRupees(50));
    });

    test('does not apply below the floor — the card earns its base rate', () {
      expect(evaluate(card, ctx(amount: 499)).expectedValue, Money.fromRupees(4.99));
    });
  });

  group('maximum transaction', () {
    // "10% on the first ₹5,000 per transaction", base rate 1% above that.
    final card = _card(rules: [_rule(maxTxn: Money.fromRupees(5000), rate: 10)]);

    test('the whole amount earns the bonus when under the ceiling', () {
      expect(evaluate(card, ctx(amount: 3000)).expectedValue, Money.fromRupees(300));
    });

    test('splits at the ceiling rather than voiding the rule or paying it in full', () {
      // ₹5,000 at 10% = ₹500, plus ₹3,000 at the 1% base = ₹30.
      final r = evaluate(card, ctx(amount: 8000));
      expect(r.expectedValue, Money.fromRupees(530));
      expect(
        r.reasonLines.any((l) => l.contains('above this rule')),
        isTrue,
        reason: 'the split has to be explained, not just applied',
      );
    });
  });

  group('catalogue validity window', () {
    test('a rule whose window has closed does not apply', () {
      final card = _card(
        rules: [_rule(rate: 10, effectiveTo: DateTime(2026, 3, 31))],
      );
      expect(
        evaluate(card, ctx(now: DateTime(2026, 4, 1))).expectedValue,
        Money.fromRupees(10),
        reason: 'expired promo rates must stop being recommended',
      );
    });

    test('effective_to includes the whole of its final day', () {
      final card = _card(rules: [_rule(rate: 10, effectiveTo: DateTime(2026, 3, 31))]);
      expect(
        evaluate(card, ctx(now: DateTime(2026, 3, 31, 18, 0))).expectedValue,
        Money.fromRupees(100),
      );
    });

    test('a rule that has not started yet does not apply', () {
      final card = _card(rules: [_rule(rate: 10, effectiveFrom: DateTime(2026, 9, 1))]);
      expect(evaluate(card, ctx(now: DateTime(2026, 8, 25))).expectedValue, Money.fromRupees(10));
    });

    test('omitting `now` keeps the pre-existing behaviour of ignoring windows', () {
      // A caller that has not been updated must degrade to the old answer,
      // not silently drop every dated rule.
      final card = _card(rules: [_rule(rate: 10, effectiveTo: DateTime(2020, 1, 1))]);
      expect(evaluate(card, ctx()).expectedValue, Money.fromRupees(100));
    });
  });

  group('category exclusions', () {
    test('a card-level exclusion earns nothing, not even the base rate', () {
      final card = _card(
        rules: [_rule(rate: 5)],
        excludedCategories: ['rent'],
      );
      final r = evaluate(card, ctx(categoryId: 'rent'));
      expect(r.isExcluded, isTrue);
      expect(r.expectedValue, const Money.zero());
      expect(r.exclusionReason, contains("doesn't earn rewards"));
    });

    test('a rule-level exclusion falls through to the base rate', () {
      // Distinct from the card-level case: the card still earns, just not
      // at the accelerated rate.
      final card = _card(
        rules: [_rule(rate: 10, excludedCategoryIds: ['fuel'])],
      );
      final r = evaluate(card, ctx(categoryId: 'fuel'));
      expect(r.isExcluded, isFalse);
      expect(r.expectedValue, Money.fromRupees(10));
    });

    test('an uncategorized spend is never treated as excluded', () {
      // We don't know what it is; guessing "excluded" would under-report.
      final card = _card(rules: [_rule(rate: 5)], excludedCategories: ['rent']);
      expect(evaluate(card, ctx(categoryId: null)).isExcluded, isFalse);
    });
  });

  group('post-cap rate resolution', () {
    CapRule spendCap({double? postCapRate, RewardUnit? postCapUnit}) => CapRule(
          id: 'cap',
          rewardRuleId: 'r',
          label: '10% cap',
          capValue: Money.fromRupees(3000),
          measure: CapMeasure.spendAmount,
          postCapRate: postCapRate,
          postCapUnit: postCapUnit,
          period: CapPeriod.calendarMonth,
        );

    test('an exhausted cap falls back to the card base rate, not to zero', () {
      // The headline case: a 10% card capped at ₹3,000/month, cap spent.
      // It should read as the ordinary 1% card it now is — not as a card
      // that earns nothing, which sorted it below genuinely worse cards.
      final card = _card(rules: [_rule(rate: 10)], caps: [spendCap()]);
      final snapshot = CardSnapshot(
        product: card,
        capRemaining: {'cap': const Money.zero()},
      );
      final r = evaluate(card, ctx(amount: 1000), snapshot: snapshot);
      expect(r.expectedValue, Money.fromRupees(10));
      expect(r.breakdown!.capNote, 'Cap reached');
      expect(r.reasonLines.single, contains('base rate of 1.0%'));
    });

    test('an explicit post-cap rate of zero is honoured as zero', () {
      // Silence and an explicit zero are different facts about a card.
      final card = _card(
        rules: [_rule(rate: 10)],
        caps: [spendCap(postCapRate: 0, postCapUnit: RewardUnit.cashbackPercent)],
      );
      final snapshot = CardSnapshot(product: card, capRemaining: {'cap': const Money.zero()});
      expect(evaluate(card, ctx(amount: 1000), snapshot: snapshot).expectedValue, const Money.zero());
    });

    test('an explicit post-cap rate is read in the rule\'s unit when none is given', () {
      final card = _card(
        rules: [_rule(rate: 10)],
        caps: [spendCap(postCapRate: 2)], // 2%, same unit as the 10% rule
      );
      final snapshot = CardSnapshot(product: card, capRemaining: {'cap': const Money.zero()});
      expect(evaluate(card, ctx(amount: 1000), snapshot: snapshot).expectedValue, Money.fromRupees(20));
    });

    test('a partially-consumed cap blends bonus and base rate', () {
      // ₹500 of headroom left, ₹1,000 spend: ₹500 at 10% + ₹500 at 1%.
      final card = _card(rules: [_rule(rate: 10)], caps: [spendCap()]);
      final snapshot = CardSnapshot(
        product: card,
        capRemaining: {'cap': Money.fromRupees(500)},
      );
      final r = evaluate(card, ctx(amount: 1000), snapshot: snapshot);
      expect(r.expectedValue, Money.fromRupees(55));
      expect(r.breakdown!.capNote, 'Only ₹500.00 of cap left');
    });

    test('a capped card still outranks a genuinely worse card', () {
      // The ordering consequence of the ₹0 bug, asserted directly: a capped
      // 10%/1%-base card must beat a 0.5% card, and used to lose to it.
      final capped = _card(id: 'capped', rules: [_rule(rate: 10)], caps: [spendCap()]);
      final weak = _card(id: 'weak', baseRate: 0.5, rules: const []);
      final ranked = engine.rank(ctx(amount: 1000), [
        CardSnapshot(product: capped, capRemaining: {'cap': const Money.zero()}),
        CardSnapshot(product: weak),
      ]);
      expect(ranked.first.card.id, 'capped');
    });
  });

  group('category-scoped caps', () {
    test('a cap keyed by category is applied, not silently ignored', () {
      // Caps modelled via category_id rather than reward_rule_id were
      // invisible to the engine, so a "5% groceries, ₹3,000/month" cap
      // modelled that way never capped anything.
      final card = _card(
        rules: [_rule(id: 'r', categoryId: 'groceries', rate: 10)],
        caps: [
          CapRule(
            id: 'cat-cap',
            categoryId: 'groceries',
            label: 'groceries cap',
            capValue: Money.fromRupees(3000),
            measure: CapMeasure.spendAmount,
            period: CapPeriod.calendarMonth,
          ),
        ],
      );
      final snapshot = CardSnapshot(product: card, capRemaining: {'cat-cap': const Money.zero()});
      final r = evaluate(card, ctx(amount: 1000, categoryId: 'groceries'), snapshot: snapshot);
      expect(r.expectedValue, Money.fromRupees(10), reason: 'cap exhausted -> base rate');
    });

    test('a cap with neither key set is not treated as card-wide', () {
      // `category_id IS NULL` must not act as a wildcard — that is exactly
      // how a rent payment came to consume a grocery cap server-side.
      final card = _card(
        rules: [_rule(id: 'r2', rate: 10)],
        caps: [
          CapRule(
            id: 'orphan',
            label: 'orphan cap',
            capValue: Money.fromRupees(3000),
            measure: CapMeasure.spendAmount,
            period: CapPeriod.calendarMonth,
          ),
        ],
      );
      final snapshot = CardSnapshot(product: card, capRemaining: {'orphan': const Money.zero()});
      expect(
        evaluate(card, ctx(amount: 1000), snapshot: snapshot).expectedValue,
        Money.fromRupees(100),
        reason: 'an unattached cap belongs to no rule and must not bite',
      );
    });
  });

  group('ruleApplies is directly assertable', () {
    test('the predicate and the ranking agree', () {
      final rule = _rule(merchantPattern: 'swiggy', minTxn: Money.fromRupees(200));
      expect(
        RecommendationEngine.ruleApplies(rule, ctx(amount: 500, merchantName: 'Swiggy')),
        isTrue,
      );
      expect(
        RecommendationEngine.ruleApplies(rule, ctx(amount: 100, merchantName: 'Swiggy')),
        isFalse,
      );
      expect(
        RecommendationEngine.ruleApplies(rule, ctx(amount: 500, merchantName: 'Zomato')),
        isFalse,
      );
    });
  });
}
