import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// The Dart half of the cross-implementation parity suite. Its JS twin is
/// api/test/reward_math.test.js, and both read the SAME fixture — see
/// db/fixtures/reward_parity_scenarios.json for why that file exists.
///
/// Short version: two implementations answer "what does this card pay on
/// this spend" — this engine ranks cards BEFORE a purchase, and
/// api/src/reward_math.js records what was earned AFTER one. They drifted,
/// and both drifts became wrong money on a user's screen: the server
/// attached caps to categories with NULL acting as a wildcard (a rent
/// payment consuming a grocery cap) and recorded value at the nominal rate
/// with no cap blending (so "earned this month" over-reported forever once
/// a cap was spent).
///
/// This side asserts `valueInr` only. `points` and `capConsumedDelta` are
/// genuinely server-only concerns — the client never writes points_ledger
/// or cap_states, it only reads them back — so asserting them here would be
/// testing an implementation this package doesn't have rather than a
/// contract it shares.
///
/// The fixture's cards are in the snake_case wire shape, so they decode
/// through the same unmodified [CardProductJson.fromJson] a live
/// `GET /catalogue` response goes through. A parsing change that breaks the
/// real contract breaks this too.
void main() {
  final fixture = jsonDecode(
    File('../../db/fixtures/reward_parity_scenarios.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final scenarios = (fixture['scenarios'] as List).cast<Map<String, dynamic>>();

  const engine = RecommendationEngine();

  TxnRail parseRail(String? value) {
    if (value == null) return TxnRail.unknown;
    const map = {
      'upi_qr': TxnRail.upiQr,
      'swipe': TxnRail.swipe,
      'online': TxnRail.online,
      'contactless': TxnRail.contactless,
      'atm': TxnRail.atm,
      'emi': TxnRail.emi,
      'unknown': TxnRail.unknown,
    };
    return map[value] ?? TxnRail.unknown;
  }

  test('the fixture is non-trivial', () {
    // Guards against a future edit silently emptying the shared contract
    // and leaving both suites green while asserting nothing.
    expect(scenarios.length, greaterThanOrEqualTo(15));
  });

  for (final scenario in scenarios) {
    test('parity: ${scenario['name']}', () {
      final card = CardProductJson.fromJson(scenario['card'] as Map<String, dynamic>);
      final txn = scenario['transaction'] as Map<String, dynamic>;
      final consumedBefore = (scenario['capConsumedBefore'] as Map<String, dynamic>);

      // cap_states stores CONSUMED; the engine takes REMAINING headroom.
      // Every cap the fixture names gets an entry, so a cap the fixture
      // says nothing about is left absent and falls back to full headroom
      // — the same default GET /user-cards produces for a period with no
      // row yet.
      final capRemaining = <String, Money>{
        for (final cap in card.capRules)
          if (consumedBefore.containsKey(cap.id))
            cap.id: cap.capValue - Money.fromRupees((consumedBefore[cap.id] as num).toDouble()),
      };

      final context = RecommendationContext(
        amount: Money.fromRupees((txn['amountInr'] as num).toDouble()),
        categoryId: txn['categoryId'] as String?,
        merchantName: txn['merchantName'] as String?,
        rail: parseRail(txn['rail'] as String?),
        now: txn['occurredAt'] == null ? null : DateTime.parse(txn['occurredAt'] as String),
      );

      final result = engine
          .rank(context, [CardSnapshot(product: card, capRemaining: capRemaining)])
          .first;

      final expected = scenario['expected'] as Map<String, dynamic>;
      if (expected['excluded'] == true) {
        expect(result.isExcluded, isTrue, reason: 'this card must not earn on this category at all');
      }
      expect(
        result.expectedValue,
        Money.fromRupees((expected['valueInr'] as num).toDouble()),
        reason: scenario['why'] as String? ?? 'value must match api/src/reward_math.js',
      );
    });
  }
}
