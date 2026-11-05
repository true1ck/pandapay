import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

/// WP9 / D30a through splitPlanProvider: the multi-card split plan reads a
/// v2 card's NATIVE consumption on every marginal step, so it neither piles
/// spend onto a card whose bonus is used up or unknown, nor reads the v1 ₹
/// measure as points.
///
/// Card "x": 5 pts/₹100, 1,500-point monthly bonus cap, base 1 pt/₹100,
/// ₹0.25 a point. A ₹500 step earns 20 bonus points on it.
String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

UserCard _owned(
  String id,
  String productId, {
  required Object? native,
  Object? consumedV1 = 0,
}) {
  final today = DateTime.now();
  return parseUserCard(
    userCardJson(
      id,
      productId,
      capStates: [
        capStateRowJson(
          '$productId-cap',
          consumed: consumedV1,
          consumedNative: native,
          capKind: native == null ? null : 'bonus_points',
          capAmount: native == null ? null : 1500,
          periodStart: native == null
              ? null
              : _day(DateTime(today.year, today.month, 1)),
          periodEnd: native == null
              ? null
              : _day(DateTime(today.year, today.month + 1, 0)),
        ),
      ],
    ),
  );
}

CardProduct _flat() => parseCard({
  'id': 'flat',
  'name': 'Flat Card',
  'network': 'visa',
  'is_upi_linkable': true,
  'point_value_inr': 0.25,
  'base_reward_unit': 'points_per_100',
  'base_reward_rate': 2,
  'accrual_rounding': 'floor',
  'reward_rules': <Map<String, dynamic>>[],
  'cap_rules': <Map<String, dynamic>>[],
});

Future<Map<String, Money>> _plan(
  List<CardProduct> catalogue,
  List<UserCard> owned,
) async {
  final container = ProviderContainer(
    overrides: [
      catalogueProvider.overrideWith((ref) async => catalogue),
      userCardsProvider.overrideWith((ref) async => owned),
      utilizationTransactionsProvider.overrideWith((ref) async => const []),
    ],
  );
  addTearDown(container.dispose);
  await container.read(catalogueProvider.future);
  await container.read(userCardsProvider.future);
  await container.read(utilizationTransactionsProvider.future);
  container.read(splitPlannerAmountProvider.notifier).state =
      Money.fromRupees(10000);
  return {
    for (final a in container.read(splitPlanProvider)) a.card.id: a.amount,
  };
}

void main() {
  test('partly used native cap: the card takes its headroom and no more',
      () async {
    final plan = await _plan(
      [parseCard(v2CardJson('x')), _flat()],
      [
        // 1,480 of 1,500 used = one ₹500 step of bonus left. The v1 `consumed`
        // is 0: a plan that read it would think the cap was fresh.
        _owned('ux', 'x', native: 1480, consumedV1: 0),
        parseUserCard(userCardJson('uf', 'flat')),
      ],
    );
    expect(plan['x'], Money.fromRupees(500));
    expect(plan['flat'], Money.fromRupees(9500));
  });

  test('the v1 measure is not read as points: huge v1 figure, native cap '
      'fresh', () async {
    final plan = await _plan(
      [parseCard(v2CardJson('x')), _flat()],
      [
        _owned('ux', 'x', native: 0, consumedV1: 99999),
        parseUserCard(userCardJson('uf', 'flat')),
      ],
    );
    expect(plan['x'], Money.fromRupees(10000));
  });

  test('a used-up card never takes spend ahead of a better base', () async {
    final plan = await _plan(
      [parseCard(v2CardJson('x')), _flat()],
      [
        _owned('ux', 'x', native: 1500),
        parseUserCard(userCardJson('uf', 'flat')),
      ],
    );
    expect(plan.keys, ['flat']);
  });

  test('an unknown native figure never takes spend ahead of a better base',
      () async {
    final plan = await _plan(
      [parseCard(v2CardJson('x')), _flat()],
      [
        _owned('ux', 'x', native: null),
        parseUserCard(userCardJson('uf', 'flat')),
      ],
    );
    expect(plan.keys, ['flat']);
  });

  test('an unknown card takes over from a declining one at its base value '
      'only', () async {
    // "x" wins the first step on its bonus, then drops to base (1 pt/₹100).
    // "l" is unknown with a 1.5 pts/₹100 base: it takes the rest, but never
    // earns the bonus it cannot confirm.
    final late = v2CardJson('l')..['base_reward_rate'] = 1.5;
    final plan = await _plan(
      [parseCard(v2CardJson('x')), parseCard(late)],
      [
        _owned('ux', 'x', native: 1480),
        _owned('ul', 'l', native: null),
      ],
    );
    expect(plan['x'], Money.fromRupees(500));
    expect(plan['l'], Money.fromRupees(9500));
  });

  test('a v1 card keeps the v1 measure in the plan', () async {
    final v1 = parseCard({
      ...v1CardJson('v', withCap: true),
      'is_upi_linkable': true,
      'base_reward_unit': 'cashback_percent',
      'base_reward_rate': 1,
      'reward_rules': [
        {
          'id': 'v-rule',
          'category_id': null,
          'merchant_pattern': null,
          'rail': null,
          'unit': 'cashback_percent',
          'rate': 10,
          'priority': 10,
        },
      ],
      'cap_rules': [
        {
          'id': 'v-cap',
          'reward_rule_id': 'v-rule',
          'category_id': null,
          'label': 'cap',
          'measure': 'reward_value',
          'period': 'calendar_month',
          'cap_value': 100,
          'post_cap_unit': 'cashback_percent',
          'post_cap_rate': 1,
        },
      ],
    });
    final low = parseCard({
      ...v1CardJson('low'),
      'is_upi_linkable': true,
      'base_reward_unit': 'cashback_percent',
      'base_reward_rate': 2,
    });
    final plan = await _plan(
      [v1, low],
      [
        parseUserCard(
          userCardJson(
            'uv',
            'v',
            capStates: [capStateRowJson('v-cap', consumed: 0)],
          ),
        ),
        parseUserCard(userCardJson('ul', 'low')),
      ],
    );
    // ₹100 of reward headroom at 10% covers ₹1,000 of spend.
    expect(plan['v']!.rupees, closeTo(1000, 500));
    expect(plan['v']!.rupees, lessThan(10000));
  });
}
