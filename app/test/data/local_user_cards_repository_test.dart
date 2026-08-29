import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local_user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Guards the "Unrecognized card" path: a guest card whose product id is no
/// longer in the catalogue (added under an older/embedded catalogue) must be
/// surfaced as removable, not silently rendered as an unusable "Card" — and
/// only when there is actually a catalogue to have missed it in.
void main() {
  late AppDatabase appDb;
  late LocalUserCardsRepository local;

  setUp(() {
    appDb = openInMemoryForTesting();
    local = LocalUserCardsRepository(appDb);
  });
  tearDown(() => appDb.close());

  CardProduct product(String id, String name) => CardProduct(
        id: id,
        name: name,
        issuerName: 'Test Bank',
        network: CardNetwork.visa,
        isUpiLinkable: false,
        pointValueInr: 1.0,
        rewardRules: const [],
        capRules: const [],
        milestoneRules: const [],
        feeWaiverRules: const [],
        benefits: const [],
      );

  test('a card whose product is in the catalogue resolves normally', () async {
    await local.addCard('p-live');
    final cards = await local.fetchUserCards(catalogue: [product('p-live', 'HDFC Millennia')]);

    expect(cards.single.cardName, 'HDFC Millennia');
    expect(cards.single.isUnresolved, isFalse);
  });

  test('a card missing from a NON-empty catalogue is marked unresolved', () async {
    await local.addCard('p-dead');
    final cards = await local.fetchUserCards(catalogue: [product('p-other', 'Some Other Card')]);

    expect(cards.single.isUnresolved, isTrue);
    expect(cards.single.cardName, 'Unrecognized card');
  });

  test('an empty catalogue never marks a card unresolved (transient, not a ghost)', () async {
    await local.addCard('p-dead');
    final cards = await local.fetchUserCards(catalogue: const []);

    expect(cards.single.isUnresolved, isFalse);
    expect(cards.single.cardName, 'Card');
  });

  test('deleteCard removes only the targeted row', () async {
    final keepId = await local.addCard('p-keep');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final dropId = await local.addCard('p-dead');

    await local.deleteCard(dropId);

    final cards = await local.fetchUserCards(catalogue: [product('p-keep', 'Kept Card')]);
    expect(cards.map((c) => c.id), [keepId]);
  });
}
