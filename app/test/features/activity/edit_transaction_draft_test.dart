// A review question about a payment that has no transaction yet (a bill receipt
// with no debit, a message the app cannot read) opens the ordinary Edit
// transaction screen, filled in with what the question already knows. Saving it
// adds the transaction and closes with `true`, which is how the question knows
// it was answered. Backing out adds nothing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Any call to the server is a failure of the test: a draft has no server id.
class _NoServerRepository implements UserCardsRepository {
  final calls = <String>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName.toString());
    throw StateError('A draft must not call the server: ${invocation.memberName}');
  }
}

TransactionEntry _draft({
  String id = 'draft:review-1',
  Money? amount,
  String? merchant = 'Airtel',
}) => TransactionEntry(
  id: id,
  amount: amount ?? Money.fromRupees(10),
  occurredAt: DateTime(2026, 11, 20, 9, 30),
  merchantName: merchant,
  instrumentKnown: false,
  entryKind: TxnEntryKind.spend,
  source: 'manual',
  status: 'active',
);

late AppDatabase _db;
late _NoServerRepository _repo;
Object? _result;
var _closed = false;

Future<void> _open(WidgetTester tester, TransactionEntry entry) async {
  _db = openInMemoryForTesting();
  addTearDown(_db.close);
  _repo = _NoServerRepository();
  _result = null;
  _closed = false;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: TextButton(
            onPressed: () async {
              _result = await context.push<Object?>(
                '/activity/${entry.id}/edit',
                extra: entry,
              );
              _closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(
        path: '/activity/:id/edit',
        builder: (context, state) => EditTransactionScreen(
          transactionId: state.pathParameters['id']!,
          initialEntry: state.extra as TransactionEntry?,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => ResponseCache(_db)),
        userCardsRepositoryProvider.overrideWithValue(_repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<List<TransactionOutboxEntry>> _queued() =>
    TransactionOutboxRepository(_db, namespace: 'user:test').all();

void main() {
  testWidgets('opens the Edit screen filled in with what the question knows', (
    tester,
  ) async {
    await _open(tester, _draft());
    final amount = tester.widget<TextField>(find.byType(TextField).at(0));
    final merchant = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(amount.controller!.text, '10.00');
    expect(merchant.controller!.text, 'Airtel');
    expect(_repo.calls, isEmpty, reason: 'nothing is fetched for a draft');
  });

  testWidgets('saving adds one transaction and hands back what was added', (
    tester,
  ) async {
    await _open(tester, _draft());
    await tester.enterText(find.byType(TextField).at(0), '12.50');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_closed, isTrue);
    final added = _result as AddedTransaction;
    expect(added.amount, Money.fromRupees(12.5));
    expect(added.merchantName, 'Airtel');
    expect(added.entryKind, TxnEntryKind.spend);
    final queued = await _queued();
    expect(
      added.clientMutationId,
      queued.single.clientMutationId,
      reason: 'the question can find the queued transaction',
    );
    final rows = await _queued();
    expect(rows, hasLength(1));
    expect(rows.single.merchantName, 'Airtel');
    expect(rows.single.amountPaise, 1250, reason: 'the edited amount, in paise');
    expect(rows.single.entryKind, TxnEntryKind.spend);
    // The lists refresh after a save, but a draft has no server id to fetch or patch.
    expect(_repo.calls, isNot(contains('Symbol("editTransaction")')));
    expect(_repo.calls, isNot(contains('Symbol("fetchTransaction")')));
  });

  testWidgets('saving queues exactly one transaction', (
    tester,
  ) async {
    await _open(tester, _draft());
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await _queued(), hasLength(1));
  });

  testWidgets('an amount of zero is refused and nothing is added', (tester) async {
    await _open(tester, _draft());
    await tester.enterText(find.byType(TextField).at(0), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid amount greater than zero.'), findsOneWidget);
    expect(_closed, isFalse);
    expect(await _queued(), isEmpty);
  });

  testWidgets('going back adds nothing and does not answer the question', (
    tester,
  ) async {
    await _open(tester, _draft());
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_closed, isTrue);
    expect(_result, isNot(isA<AddedTransaction>()));
    expect(await _queued(), isEmpty);
  });
}
