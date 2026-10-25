import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/pending_bills.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/bills_horizon.dart';
import 'package:pandapay/features/insights/central_bills_section.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo implements UserCardsRepository {
  final List<TransactionEntry> transactions;
  _FakeRepo({this.transactions = const []});

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async => transactions;

  @override
  Future<List<TransactionSplit>> fetchSplits(String transactionId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserCard _card({
  required String id,
  required String name,
  int? dueDay,
  int? statementDay,
  AutopayMode autopay = AutopayMode.off,
}) => UserCard(
  id: id,
  cardProductId: 'p-$id',
  cardName: name,
  isDefault: false,
  dueDay: dueDay,
  statementDay: statementDay,
  autopayMode: autopay,
);

Future<void> _pumpBills(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        sessionInitProvider.overrideWith((ref) async {}),
        isOnlineProvider.overrideWith((ref) => Stream.value(true)),
        categoriesProvider.overrideWith((ref) async => const []),
        ...overrides,
      ],
      child: const MaterialApp(home: Scaffold(body: BillsAndCommitmentsTab())),
    ),
  );
  await tester.pumpAndSettle();
}

List<Override> _deterministicOverrides() => [
  clockProvider.overrideWithValue(TestClock(DateTime(2026, 10, 25, 12))),
  smsBillRowsProvider.overrideWith((ref) async => const <SmsBillRow>[]),
  pastBillReceiptsProvider.overrideWith(
    (ref) async => const <PastBillReceipt>[],
  ),
  centralBillsProjectionProvider.overrideWith(
    (ref) async => const BillProjectionSnapshot.unavailable(),
  ),
];

void main() {
  testWidgets('bill category and cadence chips use the app selection palette', (
    tester,
  ) async {
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
        billsHorizonProvider.overrideWith((ref) => BillsHorizon.upcoming),
      ],
    );

    await tester.tap(find.byTooltip('Add bill or policy'));
    await tester.pumpAndSettle();

    ChoiceChip chip(String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    expect(chip('Utility').selected, isTrue);
    expect(chip('Utility').selectedColor, BambooInk.slate);
    expect(chip('Utility').backgroundColor, BambooInk.paperMuted);
    expect(chip('Utility').labelStyle?.color, BambooInk.onSlate);
    expect(chip('Monthly').selected, isTrue);
    expect(chip('Monthly').selectedColor, BambooInk.slate);
    expect(chip('Monthly').labelStyle?.color, BambooInk.onSlate);

    await tester.tap(find.text('EMI / Loan'));
    await tester.pumpAndSettle();

    expect(chip('EMI / Loan').selected, isTrue);
    expect(chip('EMI / Loan').selectedColor, BambooInk.slate);
    expect(chip('EMI / Loan').labelStyle?.color, BambooInk.onSlate);
    expect(chip('Utility').selected, isFalse);
    expect(chip('Utility').labelStyle?.color, BambooInk.ink900);
  });

  testWidgets('the horizon chip switches months and returns to upcoming', (
    tester,
  ) async {
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
        billsHorizonProvider.overrideWith((ref) => BillsHorizon.upcoming),
      ],
    );

    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsOneWidget);

    await tester.tap(find.text('Upcoming'));
    await tester.pumpAndSettle();
    expect(find.text('Choose period'), findsOneWidget);

    await tester.tap(find.text('Last month'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('Sep 2026'), findsOneWidget);
    expect(find.text('No bills in Sep 2026'), findsOneWidget);

    await tester.tap(find.text('View upcoming'));
    await tester.pumpAndSettle();

    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsOneWidget);
  });

  testWidgets('a past month derives the scheduled card due date', (
    tester,
  ) async {
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        userCardsRepositoryProvider.overrideWithValue(_FakeRepo()),
        myCardsProvider.overrideWith(
          (ref) async => [
            _card(id: 'uc1', name: 'SBI Cashback', dueDay: 16, statementDay: 1),
          ],
        ),
        billsHorizonProvider.overrideWith((ref) => BillsHorizon.lastMonth),
      ],
    );

    expect(find.text('Sep 2026'), findsOneWidget);
    expect(find.text('Credit cards'), findsOneWidget);
    expect(find.textContaining('Due 16 Sep'), findsOneWidget);
  });
}
