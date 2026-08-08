import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  final TransactionEntry entry;
  Map<String, dynamic>? lastEditArgs;
  _FakeUserCardsRepository(this.entry);

  @override
  Future<TransactionEntry> fetchTransaction(String id) async => entry;

  @override
  Future<void> editTransaction(
    String id, {
    double? amountInr,
    DateTime? occurredAt,
    String? categoryId,
    String? merchantName,
    TxnRail? rail,
    String? userCardId,
  }) async {
    lastEditArgs = {
      'id': id,
      'amountInr': amountInr,
      'merchantName': merchantName,
      'categoryId': categoryId,
      'userCardId': userCardId,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  List<UserCard> cards = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => cards),
        categoriesProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(home: EditTransactionScreen(transactionId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pre-fills amount and merchant from the existing transaction', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(1250),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Old Merchant',
      userCardId: 'uc1',
      source: 'manual',
      status: 'active',
    ));
    await _pump(tester, repo: repo);

    final amountField = tester.widget<TextField>(find.widgetWithText(TextField, 'Amount (₹)'));
    expect(amountField.controller!.text, '1250.00');
    final merchantField = tester.widget<TextField>(find.widgetWithText(TextField, 'Merchant'));
    expect(merchantField.controller!.text, 'Old Merchant');
  });

  testWidgets('rejects a zero amount without calling the repository', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(1250),
      occurredAt: DateTime(2026, 3, 1),
      userCardId: 'uc1',
      source: 'manual',
      status: 'active',
    ));
    await _pump(tester, repo: repo);

    await tester.enterText(find.widgetWithText(TextField, 'Amount (₹)'), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastEditArgs, isNull);
    expect(find.textContaining('valid amount'), findsOneWidget);
  });

  testWidgets('Save sends the edited amount and merchant to the repository', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(1250),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Old Merchant',
      userCardId: 'uc1',
      source: 'manual',
      status: 'active',
    ));
    await _pump(tester, repo: repo);

    await tester.enterText(find.widgetWithText(TextField, 'Amount (₹)'), '2000');
    await tester.enterText(find.widgetWithText(TextField, 'Merchant'), 'New Merchant');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastEditArgs?['id'], 't1');
    expect(repo.lastEditArgs?['amountInr'], 2000.0);
    expect(repo.lastEditArgs?['merchantName'], 'New Merchant');
  });
}
