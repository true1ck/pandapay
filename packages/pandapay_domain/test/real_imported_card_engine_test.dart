import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Regression coverage for api/scripts/import_card_pipeline.js: this fixture
/// is CASHBACK SBI Card exactly as it landed in a real Postgres row after
/// running the importer against CardPipeline's actual LLM-extracted JSON
/// (v_admin_card_catalogue_export output, not hand-written) — the same
/// record manually verified end-to-end during that script's build. Captured
/// here so a future change to either the importer's field mapping or the
/// engine's rule-selection logic can't silently break this real card
/// without a test noticing, the same reason card_rules_json_test.dart keeps
/// a live /catalogue capture instead of only hand-written JSON.
void main() {
  final fixture = jsonDecode(
    File('test/fixtures_real_imported_card.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final card = CardProductJson.fromJson(fixture);
  final engine = RecommendationEngine();

  test('parses without throwing and carries the real rule counts', () {
    expect(card.name, 'CASHBACK SBI Card');
    expect(card.network, CardNetwork.visa);
    expect(card.rewardRules, hasLength(14));
    expect(card.capRules, hasLength(3));
  });

  test('an online spend in a non-excluded category earns the 5% accelerator rate', () {
    final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.online);
    final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;

    expect(r.isExcluded, isFalse);
    expect(r.expectedValue, Money.fromRupees(50)); // 5% of ₹1,000
  });

  test('a swipe spend in the excluded "bills" category earns nothing, not the base rate', () {
    final billsCategoryId = card.rewardRules
        .firstWhere((r) => r.rate == 0 && r.priority == 1)
        .categoryId;
    final ctx = RecommendationContext(
      amount: Money.fromRupees(1000),
      rail: TxnRail.swipe,
      categoryId: billsCategoryId,
    );
    final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;

    expect(r.isExcluded, isFalse); // a 0% rule still matches; it isn't the same as "no rule matched"
    expect(r.expectedValue, const Money.zero());
  });

  test('the per-rule caps imported from cap_rules are visible on the parsed card', () {
    // The importer documents that aggregate-scope caps (spanning multiple
    // reward rules, e.g. this card's combined ₹4,000/cycle cashback cap)
    // import with rewardRuleId == null because RecommendationEngine only
    // matches a cap to the ONE rule it names — this assertion is what would
    // catch that limitation silently becoming "aggregate caps enforced" or
    // "no caps imported at all" in a future refactor, either of which
    // should be a deliberate change, not an accident.
    final ruleLinked = card.capRules.where((c) => c.rewardRuleId != null);
    final aggregate = card.capRules.where((c) => c.rewardRuleId == null);
    expect(ruleLinked, hasLength(2)); // the online-only and offline-only caps
    expect(aggregate, hasLength(1)); // the combined-cashback aggregate cap
  });
}
