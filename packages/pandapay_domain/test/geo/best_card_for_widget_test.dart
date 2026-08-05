import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

CardProduct _cashbackCard({
  required String id,
  required double rate,
  bool upiLinkable = true,
  String? categoryId,
}) {
  return CardProduct(
    id: id,
    name: id,
    network: CardNetwork.rupay,
    isUpiLinkable: upiLinkable,
    rewardRules: [
      RewardRule(id: '$id-rule', unit: RewardUnit.cashbackPercent, rate: rate, categoryId: categoryId),
    ],
  );
}

void main() {
  group('BestCardForWidget.pickBestCard', () {
    test('returns null for an empty wallet', () {
      const picker = BestCardForWidget();
      expect(picker.pickBestCard(cards: []), isNull);
    });

    test('picks the highest-value non-excluded card, reusing the real engine', () {
      const picker = BestCardForWidget();
      final low = _cashbackCard(id: 'low', rate: 1);
      final high = _cashbackCard(id: 'high', rate: 5);

      final best = picker.pickBestCard(cards: [
        CardSnapshot(product: low),
        CardSnapshot(product: high),
      ]);

      expect(best, isNotNull);
      expect(best!.card.id, 'high');
      expect(best.isExcluded, isFalse);
    });

    test('skips an excluded card: a card whose only rule is scoped to a different '
        'category than requested has no applicable rule, same engine gate as '
        'engine_test.dart', () {
      const picker = BestCardForWidget();
      // categoryId set (not null) so the engine's `r.categoryId == null ||
      // r.categoryId == context.categoryId` match fails for a different
      // requested category, instead of matching-anything the way a
      // null-categoryId (general) rule would.
      final onlyCard = _cashbackCard(id: 'only', rate: 5, categoryId: 'dining');

      final best = picker.pickBestCard(
        cards: [CardSnapshot(product: onlyCard)],
        categoryId: 'fuel',
      );

      expect(best, isNull);
    });

    test('a category-scoped rule beats a lower general rate when the category matches', () {
      const picker = BestCardForWidget();
      final general = _cashbackCard(id: 'general', rate: 1);
      final diningSpecial = CardProduct(
        id: 'dining-special',
        name: 'dining-special',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'r1', unit: RewardUnit.cashbackPercent, rate: 10, categoryId: 'dining', priority: 1),
        ],
      );

      final best = picker.pickBestCard(
        cards: [CardSnapshot(product: general), CardSnapshot(product: diningSpecial)],
        categoryId: 'dining',
      );

      expect(best!.card.id, 'dining-special');
    });

    test('uses the default nominal amount when none is passed, matching Home\'s own default', () {
      const picker = BestCardForWidget();
      final card = _cashbackCard(id: 'card', rate: 5);

      final best = picker.pickBestCard(cards: [CardSnapshot(product: card)]);

      // 5% of the default nominal amount (Money.fromPaise(100000) = ₹1000).
      expect(best!.expectedValue, Money.fromRupees(50));
    });
  });
}
