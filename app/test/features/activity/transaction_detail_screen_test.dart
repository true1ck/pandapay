import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  TransactionEntry entry;
  String? lastIgnoreReason;
  _FakeUserCardsRepository(this.entry);

  @override
  Future<TransactionEntry> fetchTransaction(String id) async => entry;

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    lastIgnoreReason = reason;
    entry = TransactionEntry(
      id: entry.id,
      amount: entry.amount,
      occurredAt: entry.occurredAt,
      merchantName: entry.merchantName,
      categoryId: entry.categoryId,
      categoryName: entry.categoryName,
      cardDisplayName: entry.cardDisplayName,
      userCardId: entry.userCardId,
      source: entry.source,
      status: 'ignored',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, {required _FakeUserCardsRepository repo}) async {
  final router = GoRouter(
    initialLocation: '/activity/t1',
    routes: [
      GoRoute(
        path: '/activity/:id',
        builder: (context, state) => TransactionDetailScreen(transactionId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/activity/:id/edit', builder: (context, state) => const Text('edit screen')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [userCardsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows merchant, card, category, and source for an active transaction', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(750),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Corner Store',
      categoryName: 'Groceries',
      cardDisplayName: 'My Axis Card',
      userCardId: 'uc1',
      source: 'sms',
      status: 'active',
    ));
    await _pump(tester, repo: repo);

    expect(find.text('Corner Store'), findsOneWidget);
    expect(find.text('My Axis Card'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('SMS'), findsOneWidget);
    expect(find.text('Mark as ignored (refund / reversal / transfer)'), findsOneWidget);
  });

  testWidgets('an ignored transaction shows the exclusion banner and no ignore action', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(750),
      occurredAt: DateTime(2026, 3, 1),
      userCardId: 'uc1',
      source: 'manual',
      status: 'ignored',
    ));
    await _pump(tester, repo: repo);

    expect(find.textContaining('excluded from caps and rankings'), findsOneWidget);
    expect(find.text('Mark as ignored (refund / reversal / transfer)'), findsNothing);
  });

  testWidgets('marking ignored calls the repository with the chosen reason', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(750),
      occurredAt: DateTime(2026, 3, 1),
      userCardId: 'uc1',
      source: 'manual',
      status: 'active',
    ));
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Mark as ignored (refund / reversal / transfer)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();

    expect(repo.lastIgnoreReason, 'refund');
  });
}
