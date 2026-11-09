import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/spend_trends_screen.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/main.dart' show MoneyText;
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

final _now = DateTime(2026, 11, 9, 12);
const _month = SpendReportQuery.preset(SpendPeriod.month);
const _emptyBreakdown = 'There is no breakdown available for this period yet.';

TransactionEntry _entry(
  String id,
  DateTime at, {
  int paise = 2050000,
  TxnEntryKind kind = TxnEntryKind.spend,
  String status = 'active',
}) => TransactionEntry(
  id: id,
  amount: Money.fromPaise(paise),
  occurredAt: at,
  entryKind: kind,
  merchantName: 'Test merchant',
  categoryId: 'dining',
  categoryName: 'Dining',
  cardDisplayName: 'Test card',
  userCardId: 'test-card',
  rail: TxnRail.swipe,
  instrument: TxnInstrument.creditCard,
  source: 'sms',
  status: status,
);

LedgerReadModel _model(List<TransactionEntry> rows) => LedgerReadModel(
  ledger: LedgerSnapshot(entries: [], events: []),
  transactions: rows,
);

Future<void> _pump(
  WidgetTester tester,
  LedgerReadModel model, {
  Future<List<TransactionEntry>>? details,
  Set<String> tagIds = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedSpendQueryProvider.overrideWith((ref) => _month),
        clockProvider.overrideWithValue(TestClock(_now)),
        smsV2ReportingEnabledProvider.overrideWithValue(true),
        smsV2LedgerReadModelProvider.overrideWith((ref) async => model),
        userCardsRepositoryProvider.overrideWithValue(null),
        if (details != null)
          spendPeriodTransactionsProvider.overrideWith((ref, query) => details),
        bankAccountSummariesProvider.overrideWith((ref) async => const []),
        transactionTagsProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp(home: SpendTrendsScreen(initialTagIds: tagIds)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'ledger details keep active rows within the report bounds and reload',
    () async {
      var model = _model([
        _entry('before', DateTime(2026, 10, 31, 23, 59)),
        _entry('start', DateTime(2026, 11, 1)),
        _entry('refund', DateTime(2026, 11, 5), kind: TxnEntryKind.refund),
        _entry('income', DateTime(2026, 11, 6), kind: TxnEntryKind.income),
        _entry('last', DateTime(2026, 11, 30, 23, 59, 59)),
        _entry('end', DateTime(2026, 12, 1)),
        _entry('deleted', DateTime(2026, 11, 2), status: 'deleted'),
      ]);
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(TestClock(_now)),
          smsV2ReportingEnabledProvider.overrideWithValue(true),
          smsV2LedgerReadModelProvider.overrideWith((ref) async => model),
          userCardsRepositoryProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final rows = await container.read(
        spendPeriodTransactionsProvider(_month).future,
      );
      expect(rows.map((row) => row.id), ['start', 'refund', 'income', 'last']);
      final custom = SpendReportQuery.custom(
        from: DateTime(2026, 11, 5),
        to: DateTime(2026, 11, 6),
      );
      expect(
        (await container.read(
          spendPeriodTransactionsProvider(custom).future,
        )).map((row) => row.id),
        ['refund', 'income'],
      );

      model = _model([_entry('new', DateTime(2026, 11, 9))]);
      container.invalidate(smsV2LedgerReadModelProvider);
      expect(
        (await container.read(
          spendPeriodTransactionsProvider(_month).future,
        )).map((row) => row.id),
        ['new'],
      );
    },
  );

  testWidgets('empty detail completion keeps the populated ledger breakdown', (
    tester,
  ) async {
    final details = Completer<List<TransactionEntry>>();
    await _pump(
      tester,
      _model([_entry('purchase', DateTime(2026, 11, 2))]),
      details: details.future,
    );
    final chart = find.byKey(const Key('spending_donut_chart'));
    expect(chart, findsOneWidget);
    expect(find.text(_emptyBreakdown), findsNothing);

    details.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text('₹20,500.00'), findsWidgets);
    expect(find.text(_emptyBreakdown), findsNothing);
    expect(chart, findsOneWidget);
  });

  testWidgets(
    'ledger-backed screen has expandable payments without an API lookup',
    (tester) async {
      await _pump(tester, _model([_entry('purchase', DateTime(2026, 11, 2))]));
      expect(find.byKey(const Key('spending_donut_chart')), findsOneWidget);
      await tester.ensureVisible(find.text('Dining').last);
      await tester.tap(find.text('Dining').last);
      await tester.pumpAndSettle();
      expect(find.text('Test merchant'), findsOneWidget);
      expect(
        find.textContaining('Transaction details are not available'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a filter with no matches stays empty despite populated ledger totals',
    (tester) async {
      await _pump(
        tester,
        _model([_entry('purchase', DateTime(2026, 11, 2))]),
        tagIds: {'missing-tag'},
      );
      expect(find.text('No transactions match these filters.'), findsOneWidget);
      expect(find.byKey(const Key('spending_donut_chart')), findsNothing);
      final summary = find.byKey(const ValueKey('spending_summary_card'));
      expect(
        tester
            .widgetList<MoneyText>(
              find.descendant(of: summary, matching: find.byType(MoneyText)),
            )
            .map((widget) => widget.amount.paise),
        everyElement(0),
      );
    },
  );

  testWidgets('a genuinely empty ledger period shows the zero-spending state', (
    tester,
  ) async {
    await _pump(tester, _model([_entry('old', DateTime(2026, 10, 2))]));
    expect(find.text('No spending recorded'), findsOneWidget);
    expect(find.byKey(const Key('spending_donut_chart')), findsNothing);
  });

  testWidgets(
    'pending details show loading instead of a false empty breakdown',
    (tester) async {
      final details = Completer<List<TransactionEntry>>();
      final full = _model([
        _entry('purchase', DateTime(2026, 11, 2)),
      ]).spendReport(_month, _now);
      final report = SpendReport(
        period: full.period,
        periodStart: full.periodStart,
        periodEnd: full.periodEnd,
        elapsedFraction: full.elapsedFraction,
        spend: full.spend,
        income: full.income,
        investment: full.investment,
        previousSpend: full.previousSpend,
        byCategory: const [],
        byMerchant: const [],
        byCard: const [],
        byInstrument: const [],
        series: const [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedSpendQueryProvider.overrideWith((ref) => _month),
            smsV2ReportingEnabledProvider.overrideWithValue(false),
            spendReportProvider.overrideWith((ref, query) async => report),
            spendPeriodTransactionsProvider.overrideWith(
              (ref, query) => details.future,
            ),
            bankAccountSummariesProvider.overrideWith((ref) async => const []),
            transactionTagsProvider.overrideWith((ref) => null),
          ],
          child: const MaterialApp(home: SpendTrendsScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('₹20,500.00'), findsWidgets);
      expect(find.text(_emptyBreakdown), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      details.complete([_entry('purchase', DateTime(2026, 11, 2))]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spending_donut_chart')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
