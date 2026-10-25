import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/pending_bills.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/bills_horizon.dart';
import 'package:pandapay/features/insights/central_bills_section.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo implements UserCardsRepository {
  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async => const [];

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

void _setHorizon(WidgetTester tester, BillsHorizon horizon) {
  ProviderScope.containerOf(
    tester.element(find.byType(BillsAndCommitmentsTab)),
  ).read(billsHorizonProvider.notifier).state = horizon;
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

  testWidgets('upcoming keeps a recently overdue unpaid commitment', (
    tester,
  ) async {
    final overdue = Commitment(
      id: 'c-overdue',
      title: 'Overdue power bill',
      category: CommitmentCategory.utility,
      dueOn: DateTime(2026, 10, 20),
      status: CommitmentStatus.due,
      confidence: 1.0,
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => [overdue]),
        billsHorizonProvider.overrideWith((ref) => BillsHorizon.upcoming),
      ],
    );

    expect(find.text('Overdue power bill'), findsOneWidget);
    expect(find.textContaining('Past due date'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsNothing);
  });

  testWidgets('paid commitments stay in their due month, not upcoming', (
    tester,
  ) async {
    final paid = Commitment(
      id: 'c-paid',
      title: 'September internet',
      category: CommitmentCategory.telecom,
      dueOn: DateTime(2026, 9, 10),
      status: CommitmentStatus.paid,
      paidOn: DateTime(2026, 9, 9),
      confidence: 1.0,
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => [paid]),
      ],
    );

    expect(find.text('September internet'), findsNothing);

    _setHorizon(tester, BillsHorizon.lastMonth);
    await tester.pumpAndSettle();

    expect(find.text('September internet'), findsOneWidget);
    expect(find.text('Paid · due 10 Sep'), findsOneWidget);
  });

  testWidgets('autopay mandates stay out of past horizons', (tester) async {
    const mandate = BillProjection(
      id: 'm1',
      projectionKind: 'mandate',
      projectionKey: 'k1',
      status: 'active',
      projection: {
        'billerName': 'ACT Fibernet',
        'authorizationLimitInr': 2000.0,
        'asOfAt': '2026-10-20',
      },
      sourceKey: 's1',
      sourceFactIds: [],
      projectionVersion: 1,
      updatedAt: null,
    );
    await _pumpBills(
      tester,
      overrides: [
        clockProvider.overrideWithValue(TestClock(DateTime(2026, 10, 25, 12))),
        smsBillRowsProvider.overrideWith((ref) async => const <SmsBillRow>[]),
        pastBillReceiptsProvider.overrideWith(
          (ref) async => const <PastBillReceipt>[],
        ),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
        centralBillsProjectionProvider.overrideWith(
          (ref) async =>
              const BillProjectionSnapshot(available: true, projections: [mandate]),
        ),
      ],
    );

    _setHorizon(tester, BillsHorizon.currentMonth);
    await tester.pumpAndSettle();
    expect(find.text('Autopay authorizations'), findsOneWidget);

    _setHorizon(tester, BillsHorizon.lastMonth);
    await tester.pumpAndSettle();
    expect(find.text('Autopay authorizations'), findsNothing);
    expect(find.text('No bills in Sep 2026'), findsOneWidget);
  });

  testWidgets('switching months swaps linked history for open bills', (
    tester,
  ) async {
    SmsBillRow bill({
      required String id,
      required String title,
      required DateTime dueDate,
      required SmsBillState state,
    }) => SmsBillRow(
      id: id,
      title: title,
      category: CommitmentCategory.telecom,
      amountDue: Money.fromRupees(799),
      minimumDue: null,
      isMinimumOnly: false,
      dueDate: dueDate,
      receivedAt: dueDate.subtract(const Duration(days: 5)),
      isAutopay: false,
      sawFailedAttempt: false,
      state: state,
    );
    final linked = bill(
      id: 's-linked',
      title: 'September broadband',
      dueDate: DateTime(2026, 9, 15),
      state: SmsBillState.linked,
    );
    final pending = bill(
      id: 's-pending',
      title: 'October electricity',
      dueDate: DateTime(2026, 10, 28),
      state: SmsBillState.pending,
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        smsBillRowsProvider.overrideWith((ref) async => [linked, pending]),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
      ],
    );

    expect(find.text('Bill payment status'), findsOneWidget);
    expect(find.text('October electricity'), findsOneWidget);
    expect(find.text('September broadband'), findsNothing);

    _setHorizon(tester, BillsHorizon.lastMonth);
    await tester.pumpAndSettle();
    expect(find.text('Bill payment status'), findsOneWidget);
    expect(find.text('September broadband'), findsOneWidget);
    expect(find.text('October electricity'), findsNothing);
  });

  testWidgets('past empty state names the next card due and jumps back', (
    tester,
  ) async {
    final futureDue = DuePayment(
      card: _card(id: 'uc-future', name: 'Future card'),
      dueOn: DateTime(2026, 11, 16),
      daysUntilDue: 22,
      loggedThisCycle: Money.zero(),
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => [futureDue]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
      ],
    );
    _setHorizon(tester, BillsHorizon.lastMonth);
    await tester.pumpAndSettle();

    expect(find.text('No bills in Sep 2026'), findsOneWidget);
    expect(find.text('Next card due 16 Nov'), findsOneWidget);

    await tester.tap(find.text('View upcoming'));
    await tester.pumpAndSettle();

    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('Future card'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsNothing);
  });

  testWidgets('a past month prefers the issuer bill date over the saved day', (
    tester,
  ) async {
    final row = DuePayment(
      card: _card(id: 'uc1', name: 'HDFC card', dueDay: 30, statementDay: 1),
      dueOn: DateTime(2026, 10, 28),
      daysUntilDue: 3,
      loggedThisCycle: Money.zero(),
      bill: CardBill(
        statementDate: DateTime(2026, 10, 1),
        dueDate: DateTime(2026, 10, 28),
        amountDue: Money.fromRupees(1200),
        minimumDue: null,
        paidToward: Money.zero(),
        lastPaymentAt: null,
        confidence: 0.9,
      ),
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => [row]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
      ],
    );
    _setHorizon(tester, BillsHorizon.currentMonth);
    await tester.pumpAndSettle();

    expect(find.textContaining('Due 28 Oct'), findsOneWidget);
    expect(find.textContaining('Due 30 Oct'), findsNothing);
  });

  testWidgets('a subscription commitment is not a blank tab', (tester) async {
    final netflix = Commitment(
      id: 'c-sub',
      title: 'Netflix',
      category: CommitmentCategory.subscription,
      dueOn: DateTime(2026, 10, 28),
      status: CommitmentStatus.due,
      confidence: 1.0,
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => [netflix]),
      ],
    );

    expect(find.text('Subscriptions'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsNothing);
  });

  testWidgets('a local autopay mandate keeps the tab out of its empty state', (
    tester,
  ) async {
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    addTearDown(db.close);
    cache.financialStore.saveObservation('user:test', 'sms:bescom', {
      'event_type': 'autopay',
      'biller_name': 'BESCOM',
      'card_last4': '7105',
      'autopay_limit_paise': 250000,
      'received_at': '2026-10-18T09:00:00Z',
    });
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => cache),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
      ],
    );

    expect(find.text('Autopay authorizations'), findsOneWidget);
    expect(find.text('BESCOM'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsNothing);
  });

  testWidgets('a dismissed local bill falls back to the empty state', (
    tester,
  ) async {
    final projection = BillProjection.fromJson({
      'id': 'p1',
      'projectionKind': 'bill_obligation',
      'projectionKey': 'bill:bescom',
      'status': 'active',
      'projection': {
        'billerName': 'BESCOM',
        'dueDate': '2026-10-28T00:00:00.000',
        'amountInr': 1200.0,
      },
    });
    final dismissed = Commitment(
      id: 'c-dismissed',
      title: 'BESCOM',
      category: CommitmentCategory.utility,
      amount: Money.fromRupees(1200),
      dueOn: DateTime(2026, 10, 28),
      status: CommitmentStatus.dismissed,
      confidence: 1.0,
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        centralBillsProjectionProvider.overrideWith(
          (ref) async => BillProjectionSnapshot(
            available: true,
            projections: [projection],
          ),
        ),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => [dismissed]),
      ],
    );

    expect(find.text('No upcoming bills'), findsOneWidget);
    expect(find.text('BESCOM'), findsNothing);
  });

  testWidgets('past pending bills are not labelled Upcoming', (tester) async {
    final pending = SmsBillRow(
      id: 's-pending-past',
      title: 'September power',
      category: CommitmentCategory.utility,
      amountDue: Money.fromRupees(500),
      minimumDue: null,
      isMinimumOnly: false,
      dueDate: DateTime(2026, 9, 20),
      receivedAt: DateTime(2026, 9, 15),
      isAutopay: false,
      sawFailedAttempt: false,
      state: SmsBillState.pending,
    );
    final undated = SmsBillRow(
      id: 's-undated',
      title: 'September water',
      category: CommitmentCategory.utility,
      amountDue: Money.fromRupees(300),
      minimumDue: null,
      isMinimumOnly: false,
      dueDate: null,
      receivedAt: DateTime(2026, 9, 18),
      isAutopay: false,
      sawFailedAttempt: false,
      state: SmsBillState.pending,
    );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        smsBillRowsProvider.overrideWith((ref) async => [pending, undated]),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
      ],
    );
    _setHorizon(tester, BillsHorizon.lastMonth);
    await tester.pumpAndSettle();

    expect(find.text('Payment not found yet'), findsOneWidget);
    expect(find.text('No due date seen'), findsOneWidget);
    expect(find.text('Upcoming'), findsNothing);
    expect(find.textContaining('Received 18 Sep'), findsOneWidget);
  });

  testWidgets('a local load failure never renders a false empty state', (
    tester,
  ) async {
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith(
          (ref) async => throw Exception('db down'),
        ),
      ],
    );

    expect(find.text("Some bills couldn't load."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No upcoming bills'), findsNothing);
  });

  testWidgets('View all keeps the selected month', (tester) async {
    PastBillReceipt receipt(String id, String merchant, DateTime at) =>
        PastBillReceipt(
          id: id,
          sourceKey: id,
          merchant: merchant,
          amount: Money.fromRupees(500),
          occurredAt: at,
          receivedAt: at,
          status: PastBillReceiptStatus.paidLinked,
        );
    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
        pastBillReceiptsProvider.overrideWith(
          (ref) async => [
            receipt('r-sep', 'September power', DateTime(2026, 9, 12)),
            receipt('r-oct', 'October water', DateTime(2026, 10, 2)),
          ],
        ),
      ],
    );
    _setHorizon(tester, BillsHorizon.lastMonth);
    await tester.pumpAndSettle();

    expect(find.text('September power'), findsOneWidget);
    expect(find.text('October water'), findsNothing);

    await tester.tap(find.text('View all'));
    await tester.pumpAndSettle();

    expect(find.text('Past bills & receipts'), findsOneWidget);
    expect(find.text('September power'), findsOneWidget);
    expect(find.text('October water'), findsNothing);
  });

  testWidgets('the longest horizon label fits a 320px header', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpBills(
      tester,
      overrides: [
        ..._deterministicOverrides(),
        paymentsDueProvider.overrideWith((ref) async => const <DuePayment>[]),
        commitmentsProvider.overrideWith((ref) async => const <Commitment>[]),
        billsHorizonProvider.overrideWith(
          (ref) => BillsHorizon.lastThreeMonths,
        ),
      ],
    );

    expect(find.text('Aug – Oct 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
