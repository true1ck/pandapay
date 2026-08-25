import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/spend_trends_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// The Trends screen's contract: it reports, it compares, and it never
/// blends figures that mean different things.
SpendReport _report({
  double spend = 42000,
  double previousSpend = 35000,
  double income = 0,
  double investment = 0,
  double rewards = 0,
  double elapsed = 0.5,
  List<SpendBreakdownRow> byCategory = const [],
  List<CardSpendRow> byCard = const [],
  List<SpendSeriesPoint> series = const [],
}) => SpendReport(
  period: SpendPeriod.month,
  periodStart: DateTime(2026, 8, 1),
  periodEnd: DateTime(2026, 9, 1),
  elapsedFraction: elapsed,
  spend: EntryKindTotals(
    total: Money.fromRupees(spend),
    txnCount: 12,
    rewards: Money.fromRupees(rewards),
  ),
  income: EntryKindTotals(total: Money.fromRupees(income), txnCount: income > 0 ? 1 : 0, rewards: const Money.zero()),
  investment: EntryKindTotals(
    total: Money.fromRupees(investment),
    txnCount: investment > 0 ? 1 : 0,
    rewards: const Money.zero(),
  ),
  previousSpend: EntryKindTotals(
    total: Money.fromRupees(previousSpend),
    txnCount: 10,
    rewards: const Money.zero(),
  ),
  byCategory: byCategory,
  byMerchant: const [],
  byCard: byCard,
  series: series,
);

Future<void> _pump(WidgetTester tester, SpendReport? report) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        spendReportProvider.overrideWith((ref, period) async => report),
      ],
      child: const MaterialApp(home: SpendTrendsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the period total and how it compares to the period before', (tester) async {
    // The comparison is the entire point: "₹42,000" alone says nothing.
    await _pump(tester, _report(spend: 42000, previousSpend: 35000));

    expect(find.textContaining('42,000'), findsWidgets);
    expect(find.textContaining('20% more than last month'), findsOneWidget);
  });

  testWidgets('a drop is reported as less, not as a negative increase', (tester) async {
    await _pump(tester, _report(spend: 28000, previousSpend: 35000));
    expect(find.textContaining('20% less than last month'), findsOneWidget);
  });

  testWidgets('no comparison is shown when the previous period had no spend', (tester) async {
    // "Up 100%" from zero is arithmetically true and useless to read.
    await _pump(tester, _report(spend: 42000, previousSpend: 0));
    expect(find.textContaining('more than last month'), findsNothing);
    expect(find.textContaining('less than last month'), findsNothing);
  });

  testWidgets('income and investment are shown as their own lines, never folded into spend', (tester) async {
    // Blending them is the fastest way to make every figure on the screen
    // wrong: money moved into an SIP is not money spent.
    await _pump(tester, _report(spend: 42000, income: 90000, investment: 15000));

    expect(find.text('Money in'), findsOneWidget);
    expect(find.text('Spent'), findsOneWidget);
    expect(find.text('Invested'), findsOneWidget);
    expect(find.text('Left over'), findsOneWidget);
  });

  testWidgets('a period where more went out than came in reads as short, not as a negative', (tester) async {
    await _pump(tester, _report(spend: 90000, income: 40000));
    expect(find.text('Short by'), findsOneWidget);
    expect(find.text('Left over'), findsNothing);
  });

  testWidgets('the flow card is hidden entirely when there is no income or investment', (tester) async {
    // Most users only have card spend; a row of zeroes would be noise.
    await _pump(tester, _report(spend: 42000));
    expect(find.text('Money in'), findsNothing);
  });

  testWidgets('a card row reports the rate it actually paid, not its headline rate', (tester) async {
    await _pump(
      tester,
      _report(
        spend: 40000,
        rewards: 400,
        byCard: [
          CardSpendRow(
            cardId: 'uc1',
            cardName: 'Axis Magnus',
            total: Money.fromRupees(40000),
            rewards: Money.fromRupees(400),
            txnCount: 8,
            effectiveRatePerRupee: 0.01,
          ),
        ],
      ),
    );
    expect(find.textContaining('1.00% back on what you spent here'), findsOneWidget);
  });

  testWidgets('an empty period explains what would fill it rather than showing zeroes', (tester) async {
    await _pump(
      tester,
      SpendReport(
        period: SpendPeriod.month,
        periodStart: DateTime(2026, 8, 1),
        periodEnd: DateTime(2026, 9, 1),
        elapsedFraction: 0.5,
        spend: EntryKindTotals.zero,
        income: EntryKindTotals.zero,
        investment: EntryKindTotals.zero,
        previousSpend: EntryKindTotals.zero,
        byCategory: const [],
        byMerchant: const [],
        byCard: const [],
        series: const [],
      ),
    );
    expect(find.textContaining('Nothing logged'), findsOneWidget);
  });

  testWidgets('guest mode says to sign in rather than showing an empty report', (tester) async {
    await _pump(tester, null);
    expect(find.textContaining('Sign in'), findsOneWidget);
  });

  testWidgets('switching period refetches for that period', (tester) async {
    final requested = <SpendPeriod>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          spendReportProvider.overrideWith((ref, period) async {
            requested.add(period);
            return _report();
          }),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(requested, [SpendPeriod.month], reason: 'month is the default');

    await tester.tap(find.text('This week'));
    await tester.pumpAndSettle();
    expect(requested, contains(SpendPeriod.week));
  });
}
