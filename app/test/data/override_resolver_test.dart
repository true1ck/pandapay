import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/override_resolver.dart';
import 'package:pandapay/data/user_cards_repository.dart';

CardOverride _override({
  required String userCardId,
  required OverrideScope scope,
  String? vpa,
  String? merchantName,
  String? categoryId,
  bool isEnabled = true,
}) =>
    CardOverride(
      id: 'ov-$userCardId-${scope.name}',
      userCardId: userCardId,
      scope: scope,
      vpa: vpa,
      merchantName: merchantName,
      categoryId: categoryId,
      isEnabled: isEnabled,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'Card $userCardId',
    );

UserCard _userCard(String id, String cardProductId) =>
    UserCard(id: id, cardProductId: cardProductId, cardName: 'Card $id', isDefault: false);

void main() {
  group('resolveActiveOverrideCardProductId', () {
    test('a vpa-scoped override wins over a category-scoped one for the same context', () {
      final wallet = [_userCard('uc1', 'prod1'), _userCard('uc2', 'prod2')];
      final overrides = [
        _override(userCardId: 'uc2', scope: OverrideScope.category, categoryId: 'cat1'),
        _override(userCardId: 'uc1', scope: OverrideScope.vpa, vpa: 'shop@upi'),
      ];

      final result = resolveActiveOverrideCardProductId(
        overrides: overrides,
        wallet: wallet,
        categoryId: 'cat1',
        vpa: 'shop@upi',
      );

      expect(result, 'prod1');
    });

    test('a disabled override never matches', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc1', scope: OverrideScope.category, categoryId: 'cat1', isEnabled: false)];

      final result = resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, categoryId: 'cat1');

      expect(result, isNull);
    });

    test('a merchant_name override matches only on an exact, case-insensitive name', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc1', scope: OverrideScope.merchantName, merchantName: 'DMart Powai')];

      expect(
        resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, merchantName: 'dmart powai'),
        'prod1',
      );
      expect(
        resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, merchantName: 'DMart Andheri'),
        isNull,
      );
    });

    test('no context supplied and only a category override exists -> no match', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc1', scope: OverrideScope.category, categoryId: 'cat1')];

      expect(resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet), isNull);
    });

    test('an override pointing at a card no longer in the wallet is ignored, not crashed on', () {
      final wallet = [_userCard('uc1', 'prod1')];
      final overrides = [_override(userCardId: 'uc-archived', scope: OverrideScope.category, categoryId: 'cat1')];

      expect(resolveActiveOverrideCardProductId(overrides: overrides, wallet: wallet, categoryId: 'cat1'), isNull);
    });
  });
}
