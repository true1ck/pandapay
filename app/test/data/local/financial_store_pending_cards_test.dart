import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';

/// WP-C6 / L-03: a card added offline lives in the store as a pending row and
/// must survive a wallet refresh that does not know about it yet.
void main() {
  late AppDatabase db;
  late FinancialStore store;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  const server = UserCard(
    id: 'server-1',
    cardProductId: 'p1',
    cardName: 'Server Card',
    isDefault: false,
  );
  const provisional = UserCard(
    id: 'prov-1',
    cardProductId: 'p2',
    cardName: 'Queued Card',
    isDefault: false,
  );

  void insertPending(UserCard card, {int at = 1}) => db.db.execute(
    "INSERT INTO financial_entities(namespace, entity, id, payload, observed_at, pending) "
    "VALUES ('a', 'cards', ?, ?, ?, 1)",
    [card.id, jsonEncode(card.toJson()), at],
  );

  test('a pending (provisional) card survives a wallet refresh', () {
    insertPending(provisional);
    store.replaceCards('a', [server], at: DateTime.now());
    final ids = store.entities('a', 'cards').map((c) => c['id']).toSet();
    expect(ids, {'server-1', 'prov-1'});
  });

  test('a pending card also survives an archived-list refresh', () {
    insertPending(provisional);
    store.replaceCards('a', [], archived: true, at: DateTime.now());
    expect(store.entities('a', 'cards').map((c) => c['id']), ['prov-1']);
  });

  test('a settled card the server no longer lists is still removed', () {
    store.replaceCards('a', [server], at: DateTime.now());
    store.replaceCards('a', [], at: DateTime.now().add(const Duration(seconds: 1)));
    expect(store.entities('a', 'cards'), isEmpty);
  });

  test('the server copy replaces the pending row when it has the same id', () {
    insertPending(provisional);
    store.replaceCards('a', [provisional], at: DateTime.now());
    final rows = db.db.select(
      "SELECT pending FROM financial_entities WHERE namespace='a' AND entity='cards' AND id='prov-1'",
    );
    expect(rows.single['pending'], 0);
  });
}
