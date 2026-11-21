import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_read_worker.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/portable_backup/account_recovery_operation_gate.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _OfflineRepository implements UserCardsRepository {
  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async => throw const SocketException('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<List<TransactionEntry>> load(ResponseCache cache, String? cardId) {
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
      ],
    );
    addTearDown(container.dispose);
    final loader = FutureProvider<List<TransactionEntry>>(
      (ref) => loadTransactionsWithOfflineCache(
        ref,
        repo: _OfflineRepository(),
        cacheKey: 'transactions:filtered',
        cardId: cardId,
        useReportSnapshots: false,
      ),
    );
    return container.read(loader.future);
  }

  test('offline filter with zero local matches shows empty, not an error',
      () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final probe = ProviderContainer(
      overrides: [accessTokenProvider.overrideWith((ref) => 'test-token')],
    );
    addTearDown(probe.dispose);
    final ns = probe.read(cacheNamespaceProvider);
    cache.financialStore.saveTransactions(
      ns,
      [
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(100),
          occurredAt: DateTime(2026, 10, 1),
          source: 'manual',
          status: 'active',
          userCardId: 'card-a',
        ),
      ],
      completeQuery: const TransactionQuery(cardId: 'card-a'),
      at: DateTime(2026, 10, 2),
    );

    expect(await load(cache, 'card-b'), isEmpty);
  });

  test('a never-synced offline store still errors', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await expectLater(
      load(ResponseCache(database), null),
      throwsA(isA<SocketException>()),
    );
  });

  // Right after the app starts, the first local read can come back empty-handed
  // (the read worker is still starting, or the read was cut short). Offline the
  // server cannot help, so the phone's own rows must still be shown: Activity
  // opened on All time used to show "Can't reach PandaPay" for rows it held.
  group('the first local read fails right after start', () {
    late Directory directory;
    late AppDatabase database;
    late FinancialReadWorker worker;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('pandapay-c16-');
      database = AppDatabase.openUnencryptedFileForTesting(
        '${directory.path}/financial.sqlite',
      );
      worker = FinancialReadWorker(
        database.filePath!,
        recoveryGate: AccountRecoveryOperationGate(),
      );
    });

    tearDown(() async {
      await worker.close();
      database.close();
      await directory.delete(recursive: true);
    });

    String namespace() {
      final probe = ProviderContainer(
        overrides: [accessTokenProvider.overrideWith((ref) => 'test-token')],
      );
      addTearDown(probe.dispose);
      return probe.read(cacheNamespaceProvider);
    }

    TransactionEntry row(String id) => TransactionEntry(
      id: id,
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 10, 1),
      source: 'manual',
      status: 'active',
    );

    test('offline, the phone\'s rows are shown instead of an error', () async {
      final cache = _FailsFirstReadCache(database, worker);
      cache.financialStore.saveTransactions(
        namespace(),
        [row('a'), row('b')],
        completeQuery: const TransactionQuery(),
        at: DateTime(2026, 10, 2),
      );

      final rows = await load(cache, null);

      expect(rows.map((r) => r.id).toSet(), {'a', 'b'});
      expect(cache.reads, 2, reason: 'asked the phone again before giving up');
    });

    test('with nothing stored, it still errors rather than lying', () async {
      final cache = _FailsFirstReadCache(database, worker);

      await expectLater(
        load(cache, null),
        throwsA(isA<SocketException>()),
      );
    });
  });
}

/// A cache whose first transaction read fails, as a read worker that is not
/// ready yet does; every later read behaves normally.
class _FailsFirstReadCache extends ResponseCache {
  _FailsFirstReadCache(super.db, FinancialReadWorker worker)
    : super(financialReadWorker: worker);

  int reads = 0;

  @override
  Future<LocalTransactionSnapshot?> readTransactions(
    String namespace,
    TransactionQuery query, {
    bool Function()? isCurrent,
  }) {
    if (++reads == 1) throw StateError('Local query worker unavailable');
    return super.readTransactions(namespace, query, isCurrent: isCurrent);
  }
}
