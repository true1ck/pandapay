import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 7: ownedCardsWithProductProvider joins userCardsProvider (owned
/// state) with catalogueProvider (rule definitions) — the foundation every
/// Insights screen reads instead of re-deriving the join itself.
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

CardProduct _product(String id) => CardProduct(id: id, name: 'Card $id', network: CardNetwork.rupay);
UserCard _owned(String cardProductId) => UserCard(
      id: 'uc-$cardProductId',
      cardProductId: cardProductId,
      cardName: 'Card $cardProductId',
      isDefault: false,
    );

void main() {
  test('pairs each owned card with its matching catalogue product', () async {
    final container = ProviderContainer(overrides: [
      userCardsProvider.overrideWith((ref) async => [_owned('a'), _owned('b')]),
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_product('a'), _product('b')])),
    ]);
    addTearDown(container.dispose);

    await container.read(userCardsProvider.future);
    await container.read(catalogueProvider.future);

    final pairs = container.read(ownedCardsWithProductProvider).requireValue;
    expect(pairs.length, 2);
    expect(pairs.map((p) => p.$1.cardProductId), containsAll(['a', 'b']));
    expect(pairs.every((p) => p.$1.cardProductId == p.$2.id), isTrue);
  });

  test('silently drops an owned card whose product is no longer in the catalogue', () async {
    // A real scenario: a card_product gets archived/unpublished after the
    // user already added it. There's no crash-worthy inconsistency here —
    // just nothing to show for that one card until it's re-published.
    final container = ProviderContainer(overrides: [
      userCardsProvider.overrideWith((ref) async => [_owned('a'), _owned('missing')]),
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_product('a')])),
    ]);
    addTearDown(container.dispose);

    await container.read(userCardsProvider.future);
    await container.read(catalogueProvider.future);

    final pairs = container.read(ownedCardsWithProductProvider).requireValue;
    expect(pairs.length, 1);
    expect(pairs.single.$1.cardProductId, 'a');
  });

  test('is empty (not loading, not an error) when the wallet is empty', () async {
    final container = ProviderContainer(overrides: [
      userCardsProvider.overrideWith((ref) async => const []),
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([_product('a')])),
    ]);
    addTearDown(container.dispose);

    await container.read(userCardsProvider.future);
    await container.read(catalogueProvider.future);

    expect(container.read(ownedCardsWithProductProvider).requireValue, isEmpty);
  });
}
