import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// The Dart half of the shared reward-engine v2 contract (plan C4). The JS
/// twin is api/test/reward_math_v2.test.js; both load EVERY *.json file in
/// db/fixtures/reward_v2_scenarios/ and assert the same fields:
/// points, cashback_inr and value_inr to 2 decimals, rule_id, excluded,
/// and cap_deltas exactly (keys and values, zero deltas omitted).
///
/// A scenario may list the keys to compare in an optional "assert" array
/// (plan C8/D10: v1-shaped cards keep the v1 path, which doesn't produce
/// every v2 field); otherwise every key above is compared.
///
/// Each scenario is checked twice: through the pure
/// [RecommendationEngine.evaluateRewardV2] and through [RecommendationEngine.rank],
/// so the app's ranking path can't drift from the contract.
const _scenarioDir = '../../db/fixtures/reward_v2_scenarios';
const _defaultDirectoryFile = '../../db/fixtures/merchant_directory.json';

TxnRail _rail(String? value) =>
    const {
      'upi_qr': TxnRail.upiQr,
      'swipe': TxnRail.swipe,
      'online': TxnRail.online,
      'contactless': TxnRail.contactless,
      'atm': TxnRail.atm,
      'emi': TxnRail.emi,
      'unknown': TxnRail.unknown,
    }[value] ??
    TxnRail.unknown;

RecommendationContext _context(Map<String, dynamic> ctx) =>
    RecommendationContext(
      amount: Money.fromRupees((ctx['amount'] as num).toDouble()),
      categoryId: ctx['category_id'] as String?,
      categorySlug: ctx['category_slug'] as String?,
      mcc: ctx['mcc'] as String?,
      merchantName: ctx['merchant_name'] as String?,
      vpa: ctx['merchant_vpa'] as String?,
      merchantSlug: ctx['merchant_slug'] as String?,
      platform: ctx['platform'] as String?,
      rail: _rail(ctx['rail'] as String?),
      now: ctx['occurred'] == null
          ? null
          : DateTime.parse(ctx['occurred'] as String),
    );

int? _cents(Object? v) => v == null ? null : ((v as num) * 100).round();

Map<String, int> _deltaCents(Map<String, num> deltas) => {
  for (final e in deltas.entries) e.key: (e.value * 100).round(),
};

const _allKeys = {
  'points',
  'cashback_inr',
  'value_inr',
  'rule_id',
  'excluded',
  'cap_deltas',
};

void _expectMatches(
  RewardEvaluation got,
  Map<String, dynamic> expect_,
  Set<String> keys,
  String why,
) {
  if (keys.contains('excluded')) {
    expect(got.excluded, expect_['excluded'], reason: 'excluded — $why');
  }
  if (keys.contains('rule_id')) {
    expect(got.ruleId, expect_['rule_id'], reason: 'rule_id — $why');
  }
  if (keys.contains('points')) {
    expect(
      _cents(got.points),
      _cents(expect_['points']),
      reason: 'points — $why',
    );
  }
  if (keys.contains('cashback_inr')) {
    expect(
      _cents(got.cashbackInr),
      _cents(expect_['cashback_inr']),
      reason: 'cashback_inr — $why',
    );
  }
  if (keys.contains('value_inr')) {
    expect(
      _cents(got.valueInr),
      _cents(expect_['value_inr']),
      reason: 'value_inr — $why',
    );
  }
  if (keys.contains('cap_deltas')) {
    expect(
      _deltaCents(got.capDeltas),
      _deltaCents(
        (expect_['cap_deltas'] as Map<String, dynamic>).cast<String, num>(),
      ),
      reason: 'cap_deltas — $why',
    );
  }
}

void main() {
  final files =
      Directory(_scenarioDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final defaultDirectory = MerchantDirectory.fromJson(
    jsonDecode(File(_defaultDirectoryFile).readAsStringSync())
        as Map<String, dynamic>,
  );

  test('the scenario directory holds the contract and the Dart files', () {
    final names = files.map((f) => f.uri.pathSegments.last).toList();
    expect(names, containsAll(['00_contract.json', '10_dart.json']));
  });

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final directory = fixture['directory'] == null
        ? defaultDirectory
        : MerchantDirectory.fromJson(
            fixture['directory'] as Map<String, dynamic>,
          );
    final scenarios = (fixture['scenarios'] as List)
        .cast<Map<String, dynamic>>();

    group(name, () {
      test('is non-trivial', () {
        expect(scenarios, isNotEmpty);
      });

      for (final scenario in scenarios) {
        final title = scenario['name'] as String;
        final why = scenario['why'] as String? ?? title;
        test(title, () {
          // No parse-warning check here: some scenarios (e.g. 20_js K15)
          // deliberately carry unsupported values that must be skipped.
          // Clean parsing of the contract cards is pinned in
          // card_rules_v2_json_test.dart instead.
          final card = CardProductJson.fromJson(
            scenario['card'] as Map<String, dynamic>,
          );
          final ctx = _context(scenario['ctx'] as Map<String, dynamic>);
          final consumed = {
            for (final e
                in ((scenario['cap_consumed_before'] as Map?) ?? const {})
                    .entries)
              e.key as String: (e.value as num).toDouble(),
          };
          final expected = scenario['expect'] as Map<String, dynamic>;
          final keys = scenario['assert'] == null
              ? _allKeys
              : (scenario['assert'] as List).cast<String>().toSet();
          expect(
            _allKeys.containsAll(keys),
            isTrue,
            reason: 'unknown assert key in $keys',
          );

          final direct = RecommendationEngine.evaluateRewardV2(
            card,
            ctx,
            capConsumedBefore: consumed,
            directory: directory,
          );
          expect(direct.engineVersion, card.isV2Shaped ? 2 : 1);
          _expectMatches(direct, expected, keys, why);

          final ranked = RecommendationEngine(
            merchantDirectory: directory,
          ).rank(ctx, [CardSnapshot(product: card, capConsumed: consumed)]);
          final rec = ranked.single;
          // rank() gates a card that can't be used at all on this rail
          // (UPI QR on a non-UPI card) before any reward maths; the
          // contract is about the reward, which the direct check covers.
          if (ctx.rail == TxnRail.upiQr && !card.isUpiLinkable) {
            expect(rec.isExcluded, isTrue);
            return;
          }
          if (card.isV2Shaped) {
            expect(rec.reward, isNotNull, reason: 'v2 cards rank through v2');
            _expectMatches(rec.reward!, expected, keys, '$why (via rank)');
          } else {
            expect(rec.reward, isNull, reason: 'v1 cards keep the v1 path');
          }
          if (keys.contains('excluded')) {
            expect(rec.isExcluded, expected['excluded']);
          }
          if (keys.contains('value_inr') && expected['excluded'] != true) {
            expect(
              rec.expectedValue,
              Money.fromRupees((expected['value_inr'] as num).toDouble()),
            );
          }
        });
      }
    });
  }
}
