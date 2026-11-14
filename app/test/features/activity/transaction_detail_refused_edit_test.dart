import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart'
    show withPickedDate;
import 'package:pandapay/features/activity/transaction_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _ns = 'user:test';

class _ServerRepo implements UserCardsRepository {
  _ServerRepo(this.entry);
  final TransactionEntry entry;
  @override
  Future<TransactionEntry> fetchTransaction(String id) async => entry;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransactionEntry _txn(String id, {required int rupees}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: DateTime(2026, 11, 12),
  merchantName: 'QA Shop',
  source: 'manual',
  status: 'active',
);

void main() {
  test('F-6: the detail leaves a refused edit and shows the server value',
      () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final store = ResponseCache(db).financialStore;
    store.saveTransactions(_ns, [_txn('t1', rupees: 11)]);
    // What the edit screen did: queue the typed command and patch the stored
    // row so every list shows the new value at once.
    store.patchTransaction(_ns, 't1', {'amount_inr': 401});
    final commands = CommandOutbox(db, namespace: _ns);
    commands.enqueue(
      kind: 'transaction_typed_fields',
      target: 't1',
      payload: {'id': 't1', 'amountInr': 401},
    );
    final container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_ns),
        responseCacheProvider.overrideWith((_) async => ResponseCache(db)),
        userCardsRepositoryProvider.overrideWithValue(
          _ServerRepo(_txn('t1', rupees: 11)),
        ),
        transactionsProvider.overrideWith((_) async => <TransactionEntry>[]),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(transactionDetailProvider('t1'), (_, _) {});
    addTearDown(sub.close);

    expect((await container.read(transactionDetailProvider('t1').future))!.amount.rupees, 401);

    // The server refuses it for good: the command is parked.
    db.db.execute('UPDATE command_outbox SET parked = 1');
    container.read(commandOutboxRevisionProvider.notifier).state++;

    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (container.read(transactionDetailProvider('t1')).valueOrNull?.amount.rupees == 11) {
        break;
      }
    }
    expect(
      container.read(transactionDetailProvider('t1')).valueOrNull?.amount.rupees,
      11,
      reason: 'the refused 401 must not stay on the detail screen',
    );
  });

  group('F-3 / date: the date picker keeps the time of day', () {
    test('a new day keeps the original hour and minute', () {
      final current = DateTime(2026, 11, 14, 17, 26, 11);
      final out = withPickedDate(current, DateTime(2026, 11, 12));
      expect(out, DateTime(2026, 11, 12, 17, 26, 11));
    });

    test('the same day returns the original instant untouched', () {
      final current = DateTime.utc(2026, 11, 14, 11, 56, 11);
      expect(withPickedDate(current, DateTime(2026, 11, 14)), current);
    });

    test('no earlier value: the picked date is used', () {
      expect(withPickedDate(null, DateTime(2026, 11, 12)), DateTime(2026, 11, 12));
    });
  });

  testWidgets('F-3: a quick-add that has not synced can be edited', (
    tester,
  ) async {
    final entry = _txn('local-outbox:m1', rupees: 55);
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheNamespaceProvider.overrideWithValue(_ns),
          responseCacheProvider.overrideWith((_) async => ResponseCache(db)),
        ],
        child: MaterialApp(
          home: TransactionDetailScreen(
            transactionId: 'local-outbox:m1',
            initialEntry: entry,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit'), findsOneWidget);
    expect(find.textContaining('editing will be available'), findsNothing);
  });
}
