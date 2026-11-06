import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/next_best_card.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../support/v2_catalogue_fixtures.dart';

/// WP9: "Use {card} for {category} instead" is the recommender over the
/// user's OTHER owned cards, silent unless one earns more than base.
final _now = DateTime(2026, 11, 15);
const _dining = SpendCategory(id: 'cat-dining', slug: 'dining', name: 'Dining');
const _fuel = SpendCategory(id: 'cat-fuel', slug: 'fuel', name: 'Fuel');

// A: 5 pts/₹100 on dining (₹1.25 per ₹100), capped at 1,500 bonus points;
// base 1 pt/₹100 (₹0.25 per ₹100).
CardProduct _capped() =>
    parseCard(v2CardJson('a', name: 'Capped Card', categoryId: 'cat-dining'));

UserCard _ownedA({Object? native = 1500}) => parseUserCard(
  userCardJson(
    'ua',
    'a',
    capStates: [
      capStateRowJson(
        'a-cap',
        consumed: 0,
        consumedNative: native,
        capKind: native == null ? null : 'bonus_points',
        capAmount: native == null ? null : 1500,
        periodStart: native == null ? null : '2026-11-01',
        periodEnd: native == null ? null : '2026-11-30',
      ),
    ],
  ),
);

// B: 3% cashback on dining, base 1%.
CardProduct _other({double diningRate = 3, double baseRate = 1}) => CardProduct(
  id: 'b',
  name: 'Other Card',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: baseRate,
  rewardRules: [
    RewardRule(
      id: 'b-dining',
      categoryId: 'cat-dining',
      unit: RewardUnit.cashbackPercent,
      rate: diningRate,
    ),
  ],
);

UserCard _ownedB({String? nickname}) => UserCard(
  id: 'ub',
  cardProductId: 'b',
  cardName: 'Other Card',
  nickname: nickname,
  isDefault: false,
);

NextBestCard? _next({
  CardProduct? other,
  UserCard? ownedB,
  UserCard? ownedA,
  CardProduct? capped,
  CapRule? cap,
  List<SpendCategory> categories = const [_dining],
  bool includeOther = true,
}) {
  final a = capped ?? _capped();
  final ua = ownedA ?? _ownedA();
  final b = other ?? _other();
  final ub = ownedB ?? _ownedB();
  return nextBestOwnedCard(
    owned: [(ua, a), if (includeOther) (ub, b)],
    cappedCard: ua,
    cappedProduct: a,
    cap: cap ?? a.capRules.single,
    categories: categories,
    now: _now,
  );
}

void main() {
  test('names the best other owned card that earns more than base', () {
    final next = _next()!;
    expect(next.product.id, 'b');
    expect(next.message, 'Use Other Card for Dining instead');
  });

  test('uses the card\'s nickname when it has one', () {
    final next = _next(ownedB: _ownedB(nickname: 'My Dining Card'))!;
    expect(next.message, 'Use My Dining Card for Dining instead');
  });

  test('omitted when no other card earns more than its own base', () {
    expect(_next(other: _other(diningRate: 1)), isNull);
  });

  test('omitted when the other card beats its base but not the capped '
      'card\'s base (what the user earns after the cap anyway)', () {
    // Capped card: base 3% cashback. Other: 2% dining vs 1% base.
    final capped = parseCard({
      ...v2CardJson('a', name: 'Capped Card', categoryId: 'cat-dining'),
      'base_reward_unit': 'cashback_percent',
      'base_reward_rate': 3,
    });
    expect(_next(capped: capped, other: _other(diningRate: 2)), isNull);
  });

  test('never names the capped card itself, even though it ranks best', () {
    // Only the capped card is owned.
    expect(_next(includeOther: false), isNull);
  });

  test('a candidate whose own bonus cap is used up is not named', () {
    final b = parseCard(v2CardJson('b', name: 'Other Card', categoryId: 'cat-dining'));
    final ownedB = parseUserCard(
      userCardJson(
        'ub',
        'b',
        capStates: [
          capStateRowJson(
            'b-cap',
            consumed: 0,
            consumedNative: 1500,
            capKind: 'bonus_points',
            capAmount: 1500,
            periodStart: '2026-11-01',
            periodEnd: '2026-11-30',
          ),
        ],
      ),
    );
    expect(_next(other: b, ownedB: ownedB), isNull);
  });

  test('a candidate whose cap usage is unknown is not named', () {
    final b = parseCard(v2CardJson('b', name: 'Other Card', categoryId: 'cat-dining'));
    final ownedB = parseUserCard(
      userCardJson(
        'ub',
        'b',
        capStates: [
          capStateRowJson('b-cap', consumed: 0, consumedNative: null),
        ],
      ),
    );
    expect(_next(other: b, ownedB: ownedB), isNull);
  });

  test('a candidate with real headroom is named', () {
    final b = parseCard(v2CardJson('b', name: 'Other Card', categoryId: 'cat-dining'));
    final ownedB = parseUserCard(
      userCardJson(
        'ub',
        'b',
        capStates: [
          capStateRowJson(
            'b-cap',
            consumed: 0,
            consumedNative: 100,
            capKind: 'bonus_points',
            capAmount: 1500,
            periodStart: '2026-11-01',
            periodEnd: '2026-11-30',
          ),
        ],
      ),
    );
    expect(_next(other: b, ownedB: ownedB)?.product.id, 'b');
  });

  test('omitted when the category is not in the loaded list', () {
    expect(_next(categories: const [_fuel]), isNull);
    expect(_next(categories: const []), isNull);
  });

  group('capCategoryId', () {
    test('the cap\'s own category', () {
      final p = _capped();
      expect(capCategoryId(p, p.capRules.single), 'cat-dining');
    });

    test('the one category its target rules share', () {
      final p = parseCard(v2CardJson('a', categoryId: null));
      final json = v2CardJson('a');
      (json['cap_rules'] as List).single['category_id'] = null;
      (json['reward_rules'] as List).single['category_id'] = 'cat-dining';
      final product = parseCard(json);
      expect(p, isNotNull);
      expect(capCategoryId(product, product.capRules.single), 'cat-dining');
    });

    test('null for a card-wide cap', () {
      final json = v2CardJson('a', categoryId: 'cat-dining');
      (json['cap_rules'] as List).single['scope'] = 'card';
      final product = parseCard(json);
      expect(capCategoryId(product, product.capRules.single), isNull);
    });

    test('null when the targets have no single category', () {
      final json = v2CardJson('a');
      (json['cap_rules'] as List).single['category_id'] = null;
      // The one target rule is unrestricted (category null).
      final product = parseCard(json);
      expect(capCategoryId(product, product.capRules.single), isNull);
    });

    test('null when the targets span categories', () {
      final json = v2CardJson('a');
      (json['cap_rules'] as List).single['category_id'] = null;
      (json['cap_rules'] as List).single['targets'] = ['a-rule', 'a-rule-2'];
      (json['reward_rules'] as List).single['category_id'] = 'cat-dining';
      (json['reward_rules'] as List).add({
        ...(json['reward_rules'] as List).single as Map<String, dynamic>,
        'id': 'a-rule-2',
        'category_id': 'cat-fuel',
      });
      final product = parseCard(json);
      expect(capCategoryId(product, product.capRules.single), isNull);
    });
  });
}
