import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _Server extends UserCardsRepository {
  final List<String> attempted = [];
  _Server() : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  @override
  Future<String> logTransaction({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
    String? paymentMethod,
  }) async {
    attempted.add(clientMutationId!);
    return 'srv-$clientMutationId';
  }
}

/// H3-2: a queued transaction naming a card that is not on the server yet
/// waits for the remap; a parked add surfaces it instead of looping.
void main() {
  late AppDatabase db;
  late TransactionOutboxRepository outbox;
  late CommandOutbox commands;
  late _Server server;

  setUp(() {
    db = openInMemoryForTesting();
    FinancialStore(db);
    outbox = TransactionOutboxRepository(db, namespace: 'a');
    commands = CommandOutbox(db, namespace: 'a');
    server = _Server();
  });
  tearDown(() => db.close());

  Future<void> enqueue(String id, String card) => outbox.enqueue(
    userCardId: card,
    amount: Money.fromRupees(10),
    clientMutationId: id,
  );

  test('an entry for a provisional card is skipped without an attempt', () async {
    commands.enqueue(kind: 'add_card', target: 'prov-1');
    await enqueue('m1', 'prov-1');
    await enqueue('m2', 'srv-1');
    expect(await outbox.flush(server), 1);
    expect(server.attempted, ['m2']);
    final held = db.db.select(
      "SELECT attempts, parked FROM transaction_outbox_entries WHERE client_mutation_id='m1'",
    ).single;
    expect(held['attempts'], 0);
    expect(held['parked'], 0);
  });

  test('once the add is delivered the entry is sent', () async {
    commands.enqueue(kind: 'add_card', target: 'prov-1');
    await enqueue('m1', 'prov-1');
    await outbox.flush(server);
    db.db.execute("DELETE FROM command_outbox");
    expect(await outbox.flush(server), 1);
    expect(server.attempted, ['m1']);
  });

  test('a parked add parks the entry with a plain reason', () async {
    commands.enqueue(kind: 'add_card', target: 'prov-1');
    db.db.execute('UPDATE command_outbox SET parked=1');
    await enqueue('m1', 'prov-1');
    await outbox.flush(server);
    expect(server.attempted, isEmpty);
    final row = db.db.select(
      "SELECT parked, last_error FROM transaction_outbox_entries WHERE client_mutation_id='m1'",
    ).single;
    expect(row['parked'], 1);
    expect(row['last_error'], contains('card'));
  });
}
