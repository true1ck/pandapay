import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  final List<TransactionEntry> transactions;
  final List<String> editedIds = [];
  final List<String> ignoredIds = [];

  _FakeUserCardsRepository(this.transactions);

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async {
    return transactions;
  }

  @override
  Future<void> editTransaction(
    String id, {
    double? amountInr,
    DateTime? occurredAt,
    String? categoryId,
    String? userCategoryId,
    bool clearCategory = false,
    String? merchantName,
    TxnRail? rail,
    String? userCardId,
    TxnInstrument? instrument,
    TxnEntryKind? entryKind,
  }) async {
    editedIds.add(id);
  }

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    ignoredIds.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransactionEntry _txn({
  required String id,
  required Money amount,
  required DateTime occurredAt,
  String? merchantName,
}) {
  return TransactionEntry(
    id: id,
    amount: amount,
    occurredAt: occurredAt,
    merchantName: merchantName,
    userCardId: 'c1',
    entryKind: TxnEntryKind.spend,
    source: 'manual',
    status: 'active',
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  List<UserCard> cards = const [],
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: ActivityScreen()),
      ),
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
  testWidgets('shows Select transactions button and toggles selection mode', (
    tester,
  ) async {
    final now = DateTime.now();
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 't1',
        amount: Money.fromRupees(100),
        occurredAt: now,
        merchantName: 'Store A',
      ),
      _txn(
        id: 't2',
        amount: Money.fromRupees(200),
        occurredAt: now,
        merchantName: 'Store B',
      ),
    ]);

    await _pump(tester, repo: repo);

    // Initial state: "Select transactions" button is visible
    expect(find.text('Select transactions'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('0 selected'), findsNothing);

    // Tap to enter selection mode
    await tester.tap(find.text('Select transactions'));
    await tester.pumpAndSettle();

    // Now in selection mode
    expect(find.text('Cancel selection'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('0 selected'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);

    // Tap "Select all"
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();

    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('Deselect all'), findsOneWidget);

    // Tap "Cancel selection"
    await tester.tap(find.text('Cancel selection'));
    await tester.pumpAndSettle();

    expect(find.text('Select transactions'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('long press on transaction enters selection mode and selects it', (
    tester,
  ) async {
    final now = DateTime.now();
    final repo = _FakeUserCardsRepository([
      _txn(
        id: 't1',
        amount: Money.fromRupees(150),
        occurredAt: now,
        merchantName: 'Supermarket',
      ),
    ]);

    await _pump(tester, repo: repo);

    // Long press on transaction
    await tester.longPress(find.text('Supermarket'));
    await tester.pumpAndSettle();

    // Enters selection mode with 1 selected
    expect(find.text('Cancel selection'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
  });
}
