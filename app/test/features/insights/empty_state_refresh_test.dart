import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/widgets.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/insights/subscriptions_screen.dart';

/// An empty screen is exactly where a user most wants to retry, because
/// "nothing here" and "nothing here YET" look identical.
///
/// Subscriptions only appear once a third matching charge has been
/// detected, so the empty state is a waiting room, not a dead end. Found on
/// a real device: after the third charge landed, the screen kept saying "no
/// repeating charges" because the empty state had no RefreshIndicator and
/// the provider stayed cached until the user navigated away and back.
void main() {
  testWidgets('the subscriptions empty state can be pulled to refresh', (tester) async {
    var fetches = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            fetches += 1;
            return const RecurringReport(series: [], totalAnnual: Money.zero());
          }),
        ],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No repeating charges'), findsOneWidget);
    expect(
      find.byType(RefreshableEmptyState),
      findsOneWidget,
      reason: 'a plain EmptyState is not scrollable, so a pull gesture would never register',
    );
    expect(fetches, 1);

    await tester.fling(find.byType(RefreshableEmptyState), const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(fetches, greaterThan(1), reason: 'the pull must actually refetch');
  });
}
