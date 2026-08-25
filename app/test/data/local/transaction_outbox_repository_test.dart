import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
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
    String? merchantName,
    DateTime? occurredAt,
    String? note,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
  }) async {
    if (shouldFail) throw ApiException('offline');
    sent.add({'userCardId': userCardId, 'amount': amount});
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

  test('flush leaves a failing entry queued with lastError set, and still sends the rest', () async {
    await outbox.enqueue(userCardId: 'uc1', amount: Money.fromRupees(100));
    final repo = _FakeUserCardsRepository(shouldFail: true);

    final sentCount = await outbox.flush(repo);

    expect(sentCount, 0);
    final remaining = await outbox.pending();
    expect(remaining, hasLength(1));
    expect(remaining.single.lastError, isNotNull);
  });
}
