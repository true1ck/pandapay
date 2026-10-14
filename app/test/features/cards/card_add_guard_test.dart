import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/card_add_guard.dart';

void main() {
  UserCard card(String productId) => UserCard(
    id: 'user-$productId',
    cardProductId: productId,
    cardName: productId,
    isDefault: false,
  );

  test('separates owned products and removes duplicate requests', () {
    final plan = planCardAdds(
      ['owned', 'new', 'new', 'owned', 'another'],
      [card('owned')],
    );

    expect(plan.alreadyPresent, ['owned']);
    expect(plan.idsToAdd, ['new', 'another']);
  });

  test('does not treat a different product as an existing card', () {
    final plan = planCardAdds(['axis-ace'], [card('axis-flipkart')]);

    expect(plan.alreadyPresent, isEmpty);
    expect(plan.idsToAdd, ['axis-ace']);
  });
}
