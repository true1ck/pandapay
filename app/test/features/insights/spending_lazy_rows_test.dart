import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/spend_trends_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _MeasuredEntry extends TransactionEntry {
  final void Function() onCategoryRead;

  _MeasuredEntry(int index, this.onCategoryRead)
    : super(
        id: 'transaction-$index',
        amount: Money.fromPaise(100),
        occurredAt: DateTime(2026, 8, 10),
        categoryId: 'category-$index',
        categoryName: 'Category $index',
        merchantName: 'Merchant $index',
        source: 'manual',
        status: 'active',
      );

  @override
  String get categoryLabel {
    onCategoryRead();
    return super.categoryLabel;
  }
}

void main() {
  testWidgets('materializes only visible spending breakdown rows', (
    tester,
  ) async {
    var categoryReads = 0;
    final transactions = [
      for (var index = 0; index < 100; index++)
        _MeasuredEntry(index, () => categoryReads++),
    ];
    final report = SpendReport(
      period: SpendPeriod.month,
      periodStart: DateTime(2026, 8, 1),
      periodEnd: DateTime(2026, 9, 1),
      elapsedFraction: 1,
      spend: EntryKindTotals(
        total: Money.fromPaise(10000),
        txnCount: 100,
        rewards: const Money.zero(),
      ),
      income: EntryKindTotals.zero,
      investment: EntryKindTotals.zero,
      previousSpend: EntryKindTotals.zero,
      byCategory: [
        for (var index = 0; index < 100; index++)
          SpendBreakdownRow(
            label: 'Category $index',
            categoryId: 'category-$index',
            total: Money.fromPaise(100),
            txnCount: 1,
          ),
      ],
      byMerchant: const [],
      byCard: const [],
      byInstrument: const [],
      series: const [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (_) => const SpendReportQuery.preset(SpendPeriod.month),
          ),
          spendReportProvider.overrideWith((ref, query) async => report),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => transactions,
          ),
          bankAccountSummariesProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Each offscreen category used to scan all 100 transactions during the
    // first build, causing at least 9,900 category-label reads before scroll.
    expect(categoryReads, lessThan(2000));
    expect(find.text('Category 99'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Category 99'),
      500,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 100,
    );
    await tester.pumpAndSettle();
    expect(find.text('Category 99'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
