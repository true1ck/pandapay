import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local_first/local_first_cards.dart';
import 'package:pandapay/data/user_cards_repository.dart';

UserCard _card(String id, {bool isDefault = false, bool archived = false}) =>
    UserCard(
      id: id,
      cardProductId: 'product-$id',
      cardName: 'Card $id',
      isDefault: isDefault,
      isArchived: archived,
    );

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late SyncQueue queue;
  late LocalFirstCards cards;

  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    queue = SyncQueue(db, namespace: 'a');
    cards = LocalFirstCards(store: store, queue: queue, namespace: 'a');
    store.replaceCards('a', [
      _card('one', isDefault: true),
      _card('two'),
      _card('three'),
      _card('gone', archived: true),
    ]);
  });

  tearDown(() {
    store.dispose();
    db.close();
  });

  Map<String, Object?> payloadOf(String entityId) {
    final change = queue.pending().firstWhere((c) => c.entityId == entityId);
    return change.payload;
  }

  test('set default flips both cards locally and queues both for the server', () {
    cards.setDefault('two');

    final byId = {
      for (final c in store.entities('a', 'cards')) c['id']: c['is_default'],
    };
    expect(byId['two'], isTrue);
    expect(byId['one'], isFalse);
    expect(payloadOf('two'), {'is_default': true});
    expect(payloadOf('one'), {'is_default': false});
    expect(queue.pending().every((c) => c.entity == 'user_cards'), isTrue);
  });

  test('setting the card that is already default queues nothing', () {
    cards.setDefault('one');
    expect(queue.pending(), isEmpty);
  });

  test('an archived or unknown card cannot become default', () {
    expect(() => cards.setDefault('gone'), throwsStateError);
    expect(() => cards.setDefault('missing'), throwsStateError);
    expect(queue.pending(), isEmpty);
  });

  test('reorder changes the local order at once and queues sort_order', () {
    cards.reorder(['three', 'one', 'two']);

    final order = [
      for (final c in store.entities('a', 'cards'))
        if (c['is_archived'] != true) c['id'],
    ];
    expect(order, ['three', 'one', 'two']);
    expect(payloadOf('three'), {'sort_order': 0});
    expect(payloadOf('one'), {'sort_order': 1});
    expect(payloadOf('two'), {'sort_order': 2});
  });

  test('dragging twice sends one sort_order per card, not two', () {
    cards.reorder(['three', 'one', 'two']);
    cards.reorder(['two', 'three', 'one']);

    expect(queue.pending(), hasLength(3));
    expect(payloadOf('two'), {'sort_order': 0});
    expect(payloadOf('one'), {'sort_order': 2});
  });
}
