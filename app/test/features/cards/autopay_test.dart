import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/my_cards_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Migration 0027's autopay state and design 02's "Best used for" line —
/// both pure enough to test without pumping the Wallet screen.

CardProduct _product({required List<RewardRule> rules, double pointValueInr = 0}) => CardProduct(
  id: 'p1',
  name: 'Test Card',
  network: CardNetwork.visa,
  pointValueInr: pointValueInr,
  rewardRules: rules,
);

RewardRule _rule({
  String? categoryId,
  required double rate,
  RewardUnit unit = RewardUnit.cashbackPercent,
  int priority = 1,
}) => RewardRule(
  id: 'r-$categoryId-$rate-$priority',
  categoryId: categoryId,
  rate: rate,
  unit: unit,
  priority: priority,
);

const _categories = [
  SpendCategory(id: 'groceries', slug: 'groceries', name: 'Groceries'),
  SpendCategory(id: 'dining', slug: 'dining', name: 'Dining'),
  SpendCategory(id: 'fuel', slug: 'fuel', name: 'Fuel'),
];

void main() {
  group('AutopayMode.fromJson', () {
    test('parses each wire value', () {
      expect(AutopayMode.fromJson('off'), AutopayMode.off);
      expect(AutopayMode.fromJson('minimum'), AutopayMode.minimum);
      expect(AutopayMode.fromJson('full'), AutopayMode.full);
    });

    test('falls back to off for null, empty and unknown values', () {
      // A server that grows a fourth mode must not crash an older client,
      // and "off" is the reading that prompts rather than reassures.
      expect(AutopayMode.fromJson(null), AutopayMode.off);
      expect(AutopayMode.fromJson(''), AutopayMode.off);
      expect(AutopayMode.fromJson('fixed_amount'), AutopayMode.off);
    });

    test('only full counts as covering the statement', () {
      // The whole reason this is not a boolean: minimum avoids a late mark
      // but leaves the balance revolving at interest.
      expect(AutopayMode.full.coversFullStatement, isTrue);
      expect(AutopayMode.minimum.coversFullStatement, isFalse);
      expect(AutopayMode.off.coversFullStatement, isFalse);
    });
  });

  group('UserCard autopay round-trip', () {
    test('defaults to off when the server omits the column', () {
      final card = UserCard.fromJson({
        'id': 'uc1',
        'card_product_id': 'p1',
        'card_name': 'Test Card',
      });
      expect(card.autopayMode, AutopayMode.off);
    });

    test('survives the offline-cache toJson/fromJson round trip', () {
      const card = UserCard(
        id: 'uc1',
        cardProductId: 'p1',
        cardName: 'Test Card',
        isDefault: false,
        autopayMode: AutopayMode.full,
      );
      expect(UserCard.fromJson(card.toJson()).autopayMode, AutopayMode.full);
    });
  });

  group('bestUsedFor', () {
    test('ranks categories by effective rate, highest first', () {
      final product = _product(
        rules: [
          _rule(categoryId: 'groceries', rate: 5),
          _rule(categoryId: 'fuel', rate: 1),
          _rule(categoryId: 'dining', rate: 3),
        ],
      );
      expect(bestUsedFor(product, _categories), ['Groceries', 'Dining']);
    });

    test('skips the catch-all rule — "best for everything" is not information', () {
      final product = _product(
        rules: [_rule(categoryId: null, rate: 10), _rule(categoryId: 'dining', rate: 2)],
      );
      expect(bestUsedFor(product, _categories), ['Dining']);
    });

    test('drops category ids the client has no name for', () {
      final product = _product(rules: [_rule(categoryId: 'not_synced_yet', rate: 9)]);
      expect(bestUsedFor(product, _categories), isEmpty);
    });

    test('de-duplicates a category carrying several rules', () {
      final product = _product(
        rules: [
          _rule(categoryId: 'dining', rate: 5, priority: 1),
          _rule(categoryId: 'dining', rate: 4, priority: 2),
          _rule(categoryId: 'fuel', rate: 1),
        ],
      );
      expect(bestUsedFor(product, _categories), ['Dining', 'Fuel']);
    });

    test('compares points and cashback on the same scale', () {
      // 2 points at ₹0.25 each is 0.5% — worse than 1% cashback, even
      // though the raw rate number is larger.
      final product = _product(
        pointValueInr: 0.25,
        rules: [
          _rule(categoryId: 'dining', rate: 2, unit: RewardUnit.pointsPer100),
          _rule(categoryId: 'fuel', rate: 1),
        ],
      );
      expect(bestUsedFor(product, _categories).first, 'Fuel');
    });

    test('ignores zero and negative rates', () {
      final product = _product(
        rules: [_rule(categoryId: 'dining', rate: 0), _rule(categoryId: 'fuel', rate: 1)],
      );
      expect(bestUsedFor(product, _categories), ['Fuel']);
    });
  });
}
