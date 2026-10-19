import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  final TransactionEntry entry;
  final Object? fetchError;
  Map<String, dynamic>? lastEditArgs;
  _FakeUserCardsRepository(this.entry, {this.fetchError});

  @override
  Future<TransactionEntry> fetchTransaction(String id) async {
    if (fetchError != null) throw fetchError!;
    return entry;
  }

  @override
  Future<void> editTransaction(
    String id, {
    double? amountInr,
    DateTime? occurredAt,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    TxnRail? rail,
    String? userCardId,
    TxnInstrument? instrument,
    TxnEntryKind? entryKind,
  }) async {
    lastEditArgs = {
      'id': id,
      'amountInr': amountInr,
      'merchantName': merchantName,
      'categoryId': categoryId,
      'userCardId': userCardId,
      'instrument': instrument,
      'entryKind': entryKind,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  List<UserCard> cards = const [],
  TransactionEntry? initialEntry,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => cards),
        categoriesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        home: EditTransactionScreen(
          transactionId: 't1',
          initialEntry: initialEntry,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pre-fills amount and merchant from the existing transaction', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Old Merchant',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final amountField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Amount (₹)'),
    );
    expect(amountField.controller!.text, '1250.00');
    final merchantField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Merchant'),
    );
    expect(merchantField.controller!.text, 'Old Merchant');
  });

  testWidgets('keeps the tapped row editable when the edit fetch loses auth', (
    tester,
  ) async {
    final entry = TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(1250),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Offline Merchant',
      userCardId: 'uc1',
      source: 'manual',
      status: 'active',
    );
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(
        entry,
        fetchError: ApiException(
          'GET /transactions/:id failed: 401 {"error":"Missing or invalid access token"}',
        ),
      ),
      initialEntry: entry,
    );

    // The route now passes the tapped row into the edit screen, so a token
    // refresh race cannot turn the form into a blank error state.
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Merchant'))
          .controller!
          .text,
      'Offline Merchant',
    );
  });

  testWidgets('rejects a zero amount without calling the repository', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.enterText(find.widgetWithText(TextField, 'Amount (₹)'), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastEditArgs, isNull);
    expect(find.textContaining('valid amount'), findsOneWidget);
  });

  testWidgets('Save sends the edited amount and merchant to the repository', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Old Merchant',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.enterText(
      find.widgetWithText(TextField, 'Amount (₹)'),
      '2000',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Merchant'),
      'New Merchant',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastEditArgs?['id'], 't1');
    expect(repo.lastEditArgs?['amountInr'], 2000.0);
    expect(repo.lastEditArgs?['merchantName'], 'New Merchant');
  });

  testWidgets('income transactions keep their kind editable without a card', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(90000),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Employer',
        instrument: TxnInstrument.upiBank,
        entryKind: TxnEntryKind.income,
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    expect(find.text('Money in'), findsOneWidget);
    expect(find.text('Card'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '95000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastEditArgs?['amountInr'], 95000.0);
    expect(repo.lastEditArgs?['entryKind'], TxnEntryKind.income);
    expect(repo.lastEditArgs?['instrument'], TxnInstrument.upiBank);
  });
}
