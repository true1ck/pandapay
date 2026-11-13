// The Insights tile and the Subscriptions page state the same yearly cost: both
// are the billing total of one filtered view, never the report's raw total
// (which still counts telecom, lender and insurance rows the page hides).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/subscription_view.dart';
import 'package:pandapay/features/insights/subscriptions_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

RecurringSeries _series(String id, String name, double yearly) => RecurringSeries(
  id: id,
  displayName: name,
  typicalAmount: Money.fromRupees(yearly / 12),
  cadenceDays: 30,
  occurrenceCount: 3,
  annualCost: Money.fromRupees(yearly),
  nextExpectedOn: DateTime.now().add(const Duration(days: 12)),
  setupConfirmed: true,
);

RecurringReport _report() {
  final series = [
    _series('netflix', 'Netflix', 7788),
    // Rows the page hides but a raw total would add.
    _series('lender', 'Example Finance Ltd', 12000),
    _series('airtel', 'Airtel Postpaid', 6000),
  ];
  return RecurringReport(
    series: series,
    totalAnnual: Money.fromRupees(7788 + 12000 + 6000),
  );
}

void main() {
  test('the tile shows the billing total of the filtered view, not the raw total', () {
    final report = _report();
    final headline = subscriptionTileHeadline(report);
    expect(headline, '${Money.fromRupees(7788).format(compact: true)}/yr');
    expect(
      headline,
      isNot('${report.totalAnnual.format(compact: true)}/yr'),
      reason: 'the raw total counts a lender and a telecom row',
    );
    expect(
      buildSubscriptionView(report.series).billingAnnual.paise,
      Money.fromRupees(7788).paise,
    );
  });

  test('no tile figure when nothing is billing', () {
    expect(subscriptionTileHeadline(null), isNull);
    expect(
      subscriptionTileHeadline(
        RecurringReport(
          series: [_series('lender', 'Example Finance Ltd', 12000)],
          totalAnnual: Money.fromRupees(12000),
        ),
      ),
      isNull,
    );
    expect(
      subscriptionTileHeadline(
        RecurringReport(
          series: [
            RecurringSeries(
              id: 'old',
              displayName: 'Hotstar',
              typicalAmount: Money.fromRupees(100),
              cadenceDays: 30,
              occurrenceCount: 3,
              annualCost: Money.fromRupees(1200),
              lifecycleStatus: 'cancelled',
              setupConfirmed: true,
            ),
          ],
          totalAnnual: Money.zero(),
        ),
      ),
      isNull,
    );
  });

  testWidgets('the page total is the same figure the tile shows', (tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final report = _report();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [recurringReportProvider.overrideWith((ref) async => report)],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final total = buildSubscriptionView(report.series).billingAnnual;
    final monthly = Money.fromPaise((total.paise / 12).round());
    expect(find.text('About ${monthly.format(hidePaise: true)} a month'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Example Finance Ltd'), findsNothing);
    expect(find.text('Airtel Postpaid'), findsNothing);
    expect(subscriptionTileHeadline(report), '${total.format(compact: true)}/yr');
  });
}
