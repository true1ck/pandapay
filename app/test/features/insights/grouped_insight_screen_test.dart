import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/grouped_insight_screen.dart';

/// The grouped insights that replaced eighteen separate hub tiles (Payments,
/// Limits & perks). Rewards has its own screen now (RewardsScreen); this
/// covers the shared container.
Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a group shows every tab label and lands on the first', (
    tester,
  ) async {
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Payments',
        tabs: [
          (label: 'Bills', body: Text('bills body')),
          (label: 'Subscriptions', body: Text('subscriptions body')),
        ],
      ),
    );

    expect(find.text('Payments'), findsOneWidget);
    expect(find.text('Bills'), findsOneWidget);
    expect(find.text('Subscriptions'), findsOneWidget);
    expect(
      find.text('bills body'),
      findsOneWidget,
      reason: 'first tab is the landing view',
    );
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('switching tab swaps the body', (tester) async {
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Payments',
        tabs: [
          (label: 'Bills', body: Text('bills body')),
          (label: 'Subscriptions', body: Text('subscriptions body')),
        ],
      ),
    );

    await tester.tap(find.text('Subscriptions'));
    await tester.pumpAndSettle();
    expect(find.text('subscriptions body'), findsOneWidget);
  });

  testWidgets('an initial index deep-links to a later tab, and is clamped', (
    tester,
  ) async {
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Payments',
        initialIndex: 7,
        tabs: [
          (label: 'Bills', body: Text('bills body')),
          (label: 'Subscriptions', body: Text('subscriptions body')),
        ],
      ),
    );
    expect(find.text('subscriptions body'), findsOneWidget);
  });

  testWidgets('vertical sections render without a swipeable tab bar', (
    tester,
  ) async {
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Limits & perks',
        verticalSections: true,
        tabs: [
          (label: 'Caps', body: Text('caps body')),
          (label: 'Milestones', body: Text('milestones body')),
        ],
      ),
    );

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('CAPS'), findsOneWidget);
    expect(find.text('MILESTONES'), findsOneWidget);
    expect(find.text('caps body'), findsOneWidget);
    expect(find.text('milestones body'), findsOneWidget);
  });
}
