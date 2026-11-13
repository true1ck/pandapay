import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository extends UserCardsRepository {
  final List<Map<String, dynamic>> sent = [];
  bool shouldFail;
  _FakeUserCardsRepository({this.shouldFail = false}) : super(apiBaseUrl: 'http://test', accessToken: 'tok');

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
    if (shouldFail) throw ApiException('offline');
    sent.add({
      'userCardId': userCardId,
      'amount': amount,
      'instrument': instrument,
      'entryKind': entryKind,
      'clientMutationId': clientMutationId,
      'paymentMethod': paymentMethod,
    });
    return 'fake-txn-id';
  }
}

void main() {
  late AppDatabase appDb;
  late TransactionOutboxRepository outbox;

  setUp(() {
    appDb = openInMemoryForTesting();
    outbox = TransactionOutboxRepository(appDb);
  });
  tearDown(() => appDb.close());

  test('enqueue then pending returns the queued entry', () async {
    await outbox.enqueue(userCardId: 'uc1', amount: Money.fromRupees(150), note: 'coffee');
    final items = await outbox.pending();
    expect(items, hasLength(1));
    expect(items.single.userCardId, 'uc1');
    expect(items.single.amountPaise, Money.fromRupees(150).paise);
    expect(items.single.note, 'coffee');
    expect(items.single.instrument, TxnInstrument.creditCard);
    expect(items.single.entryKind, TxnEntryKind.spend);
    expect(items.single.clientMutationId, isNotEmpty);
  });

  test('card-less offline entries preserve instrument and entry kind', () async {
    await outbox.enqueue(
      amount: Money.fromRupees(5000),
      instrument: TxnInstrument.upiBank,
      entryKind: TxnEntryKind.investment,
    );

    final pending = await outbox.pending();
    expect(pending.single.userCardId, isNull);
    expect(pending.single.instrument, TxnInstrument.upiBank);
    expect(pending.single.entryKind, TxnEntryKind.investment);

    final repo = _FakeUserCardsRepository();
    await outbox.flush(repo);
    expect(repo.sent.single['userCardId'], isNull);
    expect(repo.sent.single['instrument'], TxnInstrument.upiBank);
    expect(repo.sent.single['entryKind'], TxnEntryKind.investment);
  });

  test('flush sends every pending entry and removes it on success', () async {
    await outbox.enqueue(userCardId: 'uc1', amount: Money.fromRupees(100));
    await outbox.enqueue(userCardId: 'uc2', amount: Money.fromRupees(200));
    final repo = _FakeUserCardsRepository();

    final sentCount = await outbox.flush(repo);

    expect(sentCount, 2);
    expect(repo.sent, hasLength(2));
    expect(await outbox.pending(), isEmpty);
  });

  test('flush bounds a large backlog and resumes oldest entries', () async {
    for (var i = 0; i < 25; i++) {
      await outbox.enqueue(
        userCardId: 'uc$i',
        amount: Money.fromRupees(i + 1),
        clientMutationId: 'mutation-$i',
      );
    }
    final repo = _FakeUserCardsRepository();

    expect(await outbox.flush(repo, maxEntries: 20), 20);
    expect(repo.sent, hasLength(20));
    expect(await outbox.pending(), hasLength(5));
    expect(await outbox.flush(repo, maxEntries: 20), 5);
    expect(await outbox.pending(), isEmpty);
  });

  test('flush preserves the original mutation id across retries', () async {
    await outbox.enqueue(userCardId: 'uc1', amount: Money.fromRupees(100), clientMutationId: 'fixed-mutation-id');
    final repo = _FakeUserCardsRepository();
    await outbox.flush(repo);
    expect(repo.sent.single['clientMutationId'], 'fixed-mutation-id');
  });

  test('flush leaves a failing entry queued with lastError set, and still sends the rest', () async {
    await outbox.enqueue(userCardId: 'uc1', amount: Money.fromRupees(100));
    final repo = _FakeUserCardsRepository(shouldFail: true);

    final sentCount = await outbox.flush(repo);

    expect(sentCount, 0);
    final remaining = await outbox.pending();
    expect(remaining, hasLength(1));
    expect(remaining.single.lastError, isNotNull);
  });

  test('cancel takes back a queued entry once, then reports it gone', () async {
    await outbox.enqueue(userCardId: 'uc1', amount: Money.fromRupees(100), clientMutationId: 'undo-me');

    expect(outbox.cancel('undo-me'), isTrue);
    expect(await outbox.pending(), isEmpty);
    expect(outbox.cancel('undo-me'), isFalse);
  });

  test('a delivered entry can be found by its server id for Undo', () async {
    final store = FinancialStore(appDb);
    addTearDown(store.dispose);
    final withStore = TransactionOutboxRepository(
      appDb,
      namespace: outbox.namespace,
      financialStore: store,
    );
    await withStore.enqueue(userCardId: 'uc1', amount: Money.fromRupees(100), clientMutationId: 'sent-one');
    expect(withStore.syncedTransactionId('sent-one'), isNull);

    await withStore.flush(_FakeUserCardsRepository());

    expect(withStore.syncedTransactionId('sent-one'), 'fake-txn-id');
    expect(await withStore.pending(), isEmpty);
  });
}
