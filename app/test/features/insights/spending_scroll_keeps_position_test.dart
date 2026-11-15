import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/spend_trends_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

// The real spendReportProvider watches the local transaction store's revision, so any write to the store (a sync,
// an SMS import chunk, a re-read) recomputes the report. That must update the numbers in place and never send the
// person back to the top of the page while they are reading the list. A stand-in revision plays the store here.
final _revisionStandIn = StateProvider<int>((_) => 0);

SpendReport _report(int rows, {int paise = 100}) => SpendReport(
  period: SpendPeriod.month,
  periodStart: DateTime(2026, 8, 1),
  periodEnd: DateTime(2026, 9, 1),
  elapsedFraction: 1,
  spend: EntryKindTotals(total: Money.fromPaise(paise * rows), txnCount: rows, rewards: const Money.zero()),
  income: EntryKindTotals.zero,
  investment: EntryKindTotals.zero,
  previousSpend: EntryKindTotals.zero,
  byCategory: [
    for (var index = 0; index < rows; index++)
      SpendBreakdownRow(label: 'Category $index', categoryId: 'category-$index', total: Money.fromPaise(paise), txnCount: 1),
  ],
  byMerchant: const [],
  byCard: const [],
  byInstrument: const [],
  series: const [],
);

void main() {
  testWidgets('a store revision while scrolled down keeps the reader where they are', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith((_) => const SpendReportQuery.preset(SpendPeriod.month)),
          spendReportProvider.overrideWith((ref, query) async {
            ref.watch(_revisionStandIn); // what the real provider does with the transactions revision
            return _report(100);
          }),
          spendPeriodTransactionsProvider.overrideWith((ref, query) async => <TransactionEntry>[]),
          bankAccountSummariesProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Category 60'),
      500,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 200,
    );
    await tester.pumpAndSettle();
    expect(find.text('Category 60'), findsOneWidget, reason: 'scrolled down to the row');

    // A write to the transaction store, as a sync or an import does.
    final container = ProviderScope.containerOf(tester.element(find.byType(SpendTrendsScreen)));
    for (var i = 0; i < 3; i++) {
      container.read(_revisionStandIn.notifier).state++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(find.text('Category 60'), findsOneWidget, reason: 'still reading the same row, not thrown back to the top');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
