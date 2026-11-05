import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/cap_progress.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../support/v2_catalogue_fixtures.dart';

/// WP9 cap bar model: native units per cap_kind, reset date = period_end + 1,
/// "approx." when approximate, the "then ..." clause from the post-cap
/// behaviour (omitted when it would be a guess), and "Updating" for a cap
/// whose native figure is unknown.
final _now = DateTime(2026, 11, 15);

CardProduct _product({
  String capKind = 'bonus_points',
  num capAmount = 1500,
  Map<String, dynamic> capExtra = const {},
  Map<String, dynamic> cardExtra = const {},
}) => parseCard({
  ...v2CardJson('p', capKind: capKind, capAmount: capAmount, capExtra: capExtra),
  ...cardExtra,
});

UserCard _owned({
  Object? native = 1240,
  String? kind,
  Object? amount,
  String start = '2026-11-01',
  String end = '2026-11-30',
  bool approximate = false,
  bool withRow = true,
}) => parseUserCard(
  userCardJson(
    'uc',
    'p',
    capStates: [
      if (withRow)
        capStateRowJson(
          'p-cap',
          consumed: 0,
          consumedNative: native,
          capKind: kind ?? 'bonus_points',
          capAmount: amount ?? 1500,
          periodStart: start,
          periodEnd: end,
          approximate: approximate,
        ),
    ],
  ),
);

CapProgress _progress(CardProduct product, UserCard? owned, {DateTime? now}) {
  final progress = capProgressFor(
    product: product,
    cap: product.capRules.first,
    owned: owned,
    now: now ?? _now,
  );
  expect(progress, isNotNull);
  return progress!;
}

void main() {
  group('the brief\'s example line', () {
    test('1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100', () {
      final p = _progress(_product(), _owned());
      expect(
        p.summary,
        '1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100',
      );
    });
  });

  group('units by cap_kind', () {
    test('points kinds say "pts"', () {
      for (final kind in ['bonus_points', 'total_points']) {
        final p = _progress(
          _product(capKind: kind),
          _owned(kind: kind),
        );
        expect(p.unit, CapUnit.points);
        expect(p.consumptionText, '1,240 / 1,500 pts');
      }
    });

    test('cashback kinds say "₹"', () {
      for (final kind in ['bonus_cashback', 'total_cashback']) {
        final p = _progress(
          _product(capKind: kind, capAmount: 500),
          _owned(native: 240, kind: kind, amount: 500),
        );
        expect(p.unit, CapUnit.cashback);
        expect(p.consumptionText, '₹240 / ₹500');
      }
    });

    test('eligible spend says "₹ spent"', () {
      final p = _progress(
        _product(capKind: 'eligible_spend', capAmount: 20000),
        _owned(native: 12400, kind: 'eligible_spend', amount: 20000),
      );
      expect(p.unit, CapUnit.spend);
      expect(p.consumptionText, '₹12,400 / ₹20,000 spent');
    });

    test('transaction counts say "uses"', () {
      final p = _progress(
        _product(capKind: 'txn_count', capAmount: 3),
        _owned(native: 2, kind: 'txn_count', amount: 3),
      );
      expect(p.unit, CapUnit.uses);
      expect(p.consumptionText, '2 / 3 uses');
    });

    test('Indian grouping for lakhs', () {
      final p = _progress(
        _product(capKind: 'eligible_spend', capAmount: 150000),
        _owned(native: 125000, kind: 'eligible_spend', amount: 150000),
      );
      expect(p.consumptionText, '₹1,25,000 / ₹1,50,000 spent');
    });

    test('a fractional figure is shown, not rounded away', () {
      final p = _progress(_product(), _owned(native: 1240.5));
      expect(p.consumptionText, '1,240.50 / 1,500 pts');
    });
  });

  group('reset date', () {
    test('is period_end + 1 day', () {
      final p = _progress(_product(), _owned(end: '2026-11-30'));
      expect(p.resetsOn, DateTime(2026, 12, 1));
      expect(p.resetText, 'resets 1 Dec');
    });

    test('rolls over a month end that is not the 30th', () {
      final p = _progress(
        _product(),
        _owned(start: '2026-12-01', end: '2026-12-31'),
        now: DateTime(2026, 12, 20),
      );
      expect(p.resetText, 'resets 1 Jan');
    });

    test('says "approx." when approximate_window', () {
      final p = _progress(_product(), _owned(approximate: true));
      expect(p.resetText, 'resets approx. 1 Dec');
      expect(p.summary, contains('resets approx. 1 Dec'));
    });

    test('with no row yet, names the period instead of a date', () {
      final p = _progress(_product(), _owned(withRow: false));
      expect(p.resetsOn, isNull);
      expect(p.resetText, 'resets monthly');
      expect(p.consumedText, '0');
      expect(p.ratio, 0);
    });
  });

  group('unknown, not empty', () {
    test('a null consumed_native is unknown: "Updating…", no ratio', () {
      final p = _progress(_product(), _owned(native: null));
      expect(p.isUnknown, isTrue);
      expect(p.ratio, isNull);
      expect(p.consumed, isNull);
      expect(p.summary, 'Updating…');
      expect(p.resetsOn, isNull);
    });

    test('a figure from a period that has ended is unknown', () {
      final p = _progress(
        _product(),
        _owned(start: '2026-10-01', end: '2026-10-31'),
      );
      expect(p.isUnknown, isTrue);
      expect(p.summary, 'Updating…');
    });

    test('an unknown cap is never "reached" or near', () {
      final p = _progress(_product(), _owned(native: null));
      expect(p.isReached, isFalse);
    });

    test('a v1 figure with no row is unknown too', () {
      final owned = UserCard(
        id: 'uc',
        cardProductId: 'p',
        cardName: 'x',
        isDefault: false,
        capConsumed: const {'p-cap': Money.fromPaise(1000)},
      );
      expect(_progress(_product(), owned).isUnknown, isTrue);
    });
  });

  group('percentFloor', () {
    test('rounds down: never 100% before the cap is reached', () {
      expect(percentFloor(0.8267), 82);
      expect(percentFloor(0.9993), 99);
      expect(percentFloor(0.999999), 99);
      expect(percentFloor(1.0), 100);
      expect(percentFloor(0), 0);
    });

    test('exact figures stay exact despite floating point (0.58 x 100 is '
        '57.999...)', () {
      expect(percentFloor(0.58), 58);
      expect(percentFloor(0.57), 57);
      expect(percentFloor(0.29), 29);
      expect(percentFloor(870 / 1500), 58);
    });
  });

  group('ratio', () {
    test('is consumed over amount, clamped to 1', () {
      expect(_progress(_product(), _owned(native: 750)).ratio, 0.5);
      final over = _progress(_product(), _owned(native: 1600));
      expect(over.ratio, 1.0);
      expect(over.isReached, isTrue);
    });

    test('a card the user does not hold is at zero', () {
      final p = _progress(_product(), null);
      expect(p.ratio, 0);
      expect(p.isUnknown, isFalse);
    });
  });

  group('"then ..." clause (post-cap behaviour)', () {
    test('bonus cap: the base rate', () {
      expect(_progress(_product(), _owned()).thenText, '1 pt/₹100');
    });

    test('bonus cap on a cashback card: the base cashback', () {
      final p = _progress(
        _product(
          capKind: 'bonus_cashback',
          capAmount: 500,
          cardExtra: {
            'base_reward_unit': 'cashback_percent',
            'base_reward_rate': 1.5,
          },
        ),
        _owned(native: 100, kind: 'bonus_cashback', amount: 500),
      );
      expect(p.thenText, '1.5% cashback');
    });

    test('total cap: nothing (the engine pays nothing past a total cap)', () {
      final p = _progress(
        _product(capKind: 'total_points'),
        _owned(kind: 'total_points'),
      );
      expect(p.thenText, 'nothing');
      expect(p.summary, endsWith('then nothing'));
    });

    test('eligible spend, post_cap_behavior base_rate', () {
      final p = _progress(
        _product(
          capKind: 'eligible_spend',
          capAmount: 20000,
          capExtra: {'post_cap_behavior': 'base_rate'},
        ),
        _owned(native: 100, kind: 'eligible_spend', amount: 20000),
      );
      expect(p.thenText, '1 pt/₹100');
    });

    test('eligible spend, post_cap_behavior zero', () {
      final p = _progress(
        _product(
          capKind: 'eligible_spend',
          capAmount: 20000,
          capExtra: {'post_cap_behavior': 'zero'},
        ),
        _owned(native: 100, kind: 'eligible_spend', amount: 20000),
      );
      expect(p.thenText, 'nothing');
    });

    test('eligible spend, custom_rate with its own unit', () {
      final p = _progress(
        _product(
          capKind: 'eligible_spend',
          capAmount: 20000,
          capExtra: {
            'post_cap_behavior': 'custom_rate',
            'post_cap_unit': 'points_per_150',
            'post_cap_rate': 2,
          },
        ),
        _owned(native: 100, kind: 'eligible_spend', amount: 20000),
      );
      expect(p.thenText, '2 pts/₹150');
    });

    test('custom_rate without a unit uses the targeted rule\'s unit', () {
      final p = _progress(
        _product(
          capKind: 'txn_count',
          capAmount: 3,
          capExtra: {'post_cap_behavior': 'custom_rate', 'post_cap_rate': 2},
        ),
        _owned(native: 1, kind: 'txn_count', amount: 3),
      );
      expect(p.thenText, '2 pts/₹100');
    });

    test('custom_rate with no rate is left out, not guessed', () {
      final p = _progress(
        _product(
          capKind: 'eligible_spend',
          capAmount: 20000,
          capExtra: {'post_cap_behavior': 'custom_rate'},
        ),
        _owned(native: 100, kind: 'eligible_spend', amount: 20000),
      );
      expect(p.thenText, isNull);
      expect(p.summary, isNot(contains('then')));
    });

    test('behaviour derived from post_cap_rate when not stated (D9.3)', () {
      final zero = _progress(
        _product(
          capKind: 'eligible_spend',
          capAmount: 20000,
          capExtra: {'post_cap_rate': 0},
        ),
        _owned(native: 100, kind: 'eligible_spend', amount: 20000),
      );
      expect(zero.thenText, 'nothing');
    });

    test('left out when the card has a base rule that differs from the '
        'card base (unsure)', () {
      final product = parseCard({
        ...v2CardJson('p'),
        'reward_rules': [
          ...(v2CardJson('p')['reward_rules'] as List),
          {
            'id': 'p-base',
            'category_id': null,
            'merchant_pattern': null,
            'rail': null,
            'unit': 'points_per_100',
            'rate': 1,
            'priority': 100,
            'rule_role': 'base',
            'block_inr': 150,
            'min_engine_version': 2,
          },
        ],
      });
      final p = _progress(product, _owned());
      expect(p.thenText, isNull);
    });

    test('left out when the card states no base rate', () {
      final p = _progress(
        _product(cardExtra: {'base_reward_unit': null, 'base_reward_rate': null}),
        _owned(),
      );
      expect(p.thenText, isNull);
    });

    test('a base rate of zero reads "nothing"', () {
      final p = _progress(
        _product(cardExtra: {'base_reward_rate': 0}),
        _owned(),
      );
      expect(p.thenText, 'nothing');
    });
  });

  group('kind and amount sources', () {
    test('the catalogue\'s current cap amount wins over the row\'s snapshot',
        () {
      final p = _progress(
        _product(capAmount: 2000),
        _owned(amount: 1500, native: 500),
      );
      expect(p.amount, 2000);
    });

    test('a legacy spend cap converts like the engine (eligible spend)', () {
      final json = v2CardJson('p');
      json['cap_rules'] = [
        {
          'id': 'p-cap',
          'reward_rule_id': null,
          'category_id': null,
          'label': 'Legacy spend cap',
          'measure': 'spend_amount',
          'period': 'calendar_month',
          'cap_value': 10000,
          'post_cap_unit': null,
          'post_cap_rate': null,
        },
      ];
      final product = parseCard(json);
      final p = capProgressFor(
        product: product,
        cap: product.capRules.single,
        owned: parseUserCard(
          userCardJson(
            'uc',
            'p',
            capStates: [
              capStateRowJson(
                'p-cap',
                consumed: 3000,
                consumedNative: 3000,
                capKind: 'eligible_spend',
                capAmount: 10000,
                periodStart: '2026-11-01',
                periodEnd: '2026-11-30',
              ),
            ],
          ),
        ),
        now: _now,
      )!;
      expect(p.kind, CapKind.eligibleSpend);
      expect(p.consumptionText, '₹3,000 / ₹10,000 spent');
    });

    test('a legacy reward-value cap on a points card converts via the point '
        'value (₹ / ₹0.25 per point)', () {
      final json = v2CardJson('p');
      json['cap_rules'] = [
        {
          'id': 'p-cap',
          'reward_rule_id': 'p-rule',
          'category_id': null,
          'label': 'Legacy value cap',
          'measure': 'reward_value',
          'period': 'calendar_month',
          'cap_value': 375,
          'post_cap_unit': null,
          'post_cap_rate': null,
        },
      ];
      final product = parseCard(json);
      final p = capProgressFor(
        product: product,
        cap: product.capRules.single,
        owned: null,
        now: _now,
      )!;
      expect(p.kind, CapKind.totalPoints);
      expect(p.amount, 1500);
    });

    test('a legacy reward-value cap with no point value cannot be stated: '
        'null, shown the v1 way', () {
      final json = v2CardJson('p')..['point_value_inr'] = 0;
      json['cap_rules'] = [
        {
          'id': 'p-cap',
          'reward_rule_id': null,
          'category_id': null,
          'label': 'Legacy value cap',
          'measure': 'reward_value',
          'period': 'calendar_month',
          'cap_value': 375,
          'post_cap_unit': null,
          'post_cap_rate': null,
        },
      ];
      final product = parseCard(json);
      expect(
        capProgressFor(
          product: product,
          cap: product.capRules.single,
          owned: null,
          now: _now,
        ),
        isNull,
      );
    });

    test('capProgressesFor lists every statable cap in catalogue order', () {
      final json = v2CardJson('p');
      (json['cap_rules'] as List).add({
        ...(json['cap_rules'] as List).single as Map<String, dynamic>,
        'id': 'p-cap-2',
        'cap_kind': 'txn_count',
        'cap_amount': 4,
      });
      final product = parseCard(json);
      final all = capProgressesFor(product: product, now: _now);
      expect(all.map((p) => p.cap.id), ['p-cap', 'p-cap-2']);
    });
  });
}
