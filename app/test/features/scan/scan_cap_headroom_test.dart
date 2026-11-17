import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card({List<CapRule> caps = const []}) => CardProduct(
  id: 'c1',
  name: 'Card One',
  network: CardNetwork.rupay,
  isUpiLinkable: true,
  rewardRules: const [
    RewardRule(
      id: 'r1',
      priority: 1,
      unit: RewardUnit.cashbackPercent,
      rate: 0.05,
    ),
  ],
  capRules: caps,
);

CapRule _cap(String id, int rupees, CapPeriod period, {CapMeasure measure = CapMeasure.rewardValue}) =>
    CapRule(
      id: id,
      label: id,
      capValue: Money.fromRupees(rupees.toDouble()),
      measure: measure,
      period: period,
    );

Recommendation _rec(CardProduct card) => Recommendation(
  card: card,
  expectedValue: Money.fromRupees(5),
  confidence: Confidence.confirmed,
  reasonLines: const [],
);

UserCard _owned(Map<String, Money> consumed) => UserCard(
  id: 'u1',
  cardProductId: 'c1',
  cardName: 'Card One',
  isDefault: false,
  capConsumed: consumed,
);

void main() {
  final now = DateTime(2026, 11, 17);

  test('says how much of the reward limit is left, and for which period', () {
    final line = scanCapHeadroom(
      recommendation: _rec(_card(caps: [_cap('m', 500, CapPeriod.calendarMonth)])),
      owned: _owned({'m': Money.fromRupees(240)}),
      now: now,
    )!;
    expect(line.text, '₹260 rewards left this month');
    expect(line.reached, isFalse);
    expect(line.warn, isFalse);
  });

  test('warns near the limit and says when it is used up', () {
    final near = scanCapHeadroom(
      recommendation: _rec(_card(caps: [_cap('q', 1000, CapPeriod.quarter)])),
      owned: _owned({'q': Money.fromRupees(900)}),
      now: now,
    )!;
    expect(near.text, '₹100 rewards left this quarter');
    expect(near.warn, isTrue);

    final full = scanCapHeadroom(
      recommendation: _rec(_card(caps: [_cap('q', 1000, CapPeriod.quarter)])),
      owned: _owned({'q': Money.fromRupees(1000)}),
      now: now,
    )!;
    expect(full.text, 'Limit reached this quarter');
    expect(full.reached, isTrue);
  });

  test('shows the fullest limit, and counts in uses for a count limit', () {
    final line = scanCapHeadroom(
      recommendation: _rec(
        _card(
          caps: [
            _cap('roomy', 1000, CapPeriod.calendarMonth),
            _cap('uses', 5, CapPeriod.calendarMonth, measure: CapMeasure.txnCount),
          ],
        ),
      ),
      owned: _owned({'roomy': Money.fromRupees(100), 'uses': Money.fromRupees(3)}),
      now: now,
    )!;
    expect(line.text, '2 uses left this month');
  });

  test('nothing to say for a card with no limit, or one not in the wallet', () {
    expect(
      scanCapHeadroom(recommendation: _rec(_card()), owned: _owned(const {}), now: now),
      isNull,
    );
    expect(
      scanCapHeadroom(
        recommendation: _rec(_card(caps: [_cap('m', 500, CapPeriod.calendarMonth)])),
        owned: null,
        now: now,
      ),
      isNull,
    );
  });
}
