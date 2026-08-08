import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// D1: covers what the original widget_test.dart's "Chunk 18" cases did,
/// as its own file — that suite currently fails to even compile due to
/// unrelated in-flight work elsewhere in main.dart (an H6 Appearance
/// theme-mode wiring change), not anything D1 touches.
class _FakeUserCardsRepository implements UserCardsRepository {
  final List<TransactionEntry> transactions;
  List<Map<String, dynamic>>? lastFetchArgs;
  _FakeUserCardsRepository(this.transactions);

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
  }) async {
    lastFetchArgs = [
      {'from': from, 'to': to, 'cardId': cardId, 'categoryId': categoryId, 'source': source},
    ];
    var result = transactions;
    if (cardId != null) result = result.where((t) => t.userCardId == cardId).toList();
    if (categoryId != null) result = result.where((t) => t.categoryId == categoryId).toList();
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransactionEntry _txn({
  required String id,
  required Money amount,
  required DateTime occurredAt,
  String? merchantName,
  String? categoryId,
  String? categoryName,
  String userCardId = 'uc1',
}) {
  return TransactionEntry(
    id: id,
    amount: amount,
    occurredAt: occurredAt,
    merchantName: merchantName,
    categoryId: categoryId,
    categoryName: categoryName,
    userCardId: userCardId,
    source: 'manual',
    status: 'active',
  );
}

Future<void> _pump(WidgetTester tester, {required _FakeUserCardsRepository repo, required List<UserCard> cards}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const Scaffold(body: ActivityScreen())),
      GoRoute(path: '/activity/:id', builder: (context, state) => Text('detail ${state.pathParameters['id']}')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        sessionInitProvider.overrideWith((ref) async {}),
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => cards),
        categoriesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when there are no transactions', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository(const []), cards: const []);
    expect(find.text('No activity yet'), findsOneWidget);
  });

  testWidgets('groups transactions by day and shows a spend summary', (tester) async {
    final now = DateTime.now();
    final repo = _FakeUserCardsRepository([
      _txn(id: 't1', amount: Money.fromRupees(500), occurredAt: now, merchantName: 'Today Shop'),
      _txn(id: 't2', amount: Money.fromRupees(300), occurredAt: now.subtract(const Duration(days: 1)), merchantName: 'Yesterday Shop'),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today Shop'), findsOneWidget);
    expect(find.text('Yesterday Shop'), findsOneWidget);
    expect(find.text('2 transactions'), findsOneWidget);
  });

  testWidgets('tapping a transaction navigates to its detail route', (tester) async {
    final repo = _FakeUserCardsRepository([
      _txn(id: 't1', amount: Money.fromRupees(500), occurredAt: DateTime.now(), merchantName: 'Tap Me'),
    ]);
    await _pump(tester, repo: repo, cards: const []);

    await tester.tap(find.text('Tap Me'));
    await tester.pumpAndSettle();

    expect(find.text('detail t1'), findsOneWidget);
  });
}
