import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/insights/grouped_insight_screen.dart';
import 'package:pandapay/features/insights/missed_opportunities_screen.dart';
import 'package:pandapay/features/insights/monthly_savings_screen.dart';
import 'package:pandapay/features/insights/portfolio_audit_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// The grouped insights that replaced eighteen separate hub tiles.
///
/// The risk this covers is specific: every tab body is an ORIGINAL screen
/// that used to own a whole route, and one of them
/// ([MissedOpportunitiesScreen]) carried its own Scaffold. Embedding that
/// without suppressing its chrome would stack a second app bar under the
/// group's own — visible, ugly, and easy to miss in a grid of tabs nobody
/// clicks through one by one.
class _EmptyCatalogueRepository implements CatalogueRepository {
  @override
  Future<List<CardProduct>> fetchCatalogue() async => const [];
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_EmptyCatalogueRepository()),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
        userCardsProvider.overrideWith((ref) async => const []),
        myCardsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a group shows every tab label and lands on the first', (tester) async {
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Rewards',
        tabs: [
          (label: 'This month', body: MonthlySavingsScreen()),
          (label: 'Missed', body: MissedOpportunitiesScreen(showChrome: false)),
          (label: 'By card', body: PortfolioAuditScreen()),
        ],
      ),
    );

    expect(find.text('Rewards'), findsOneWidget);
    for (final label in const ['This month', 'Missed', 'By card']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(MonthlySavingsScreen), findsOneWidget, reason: 'first tab is the landing view');
  });

  testWidgets('an embedded screen does not bring a second app bar with it', (tester) async {
    // MissedOpportunitiesScreen owns a Scaffold when reached by its own
    // route. Inside a group it must render body-only, or the user sees two
    // stacked headers.
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Rewards',
        tabs: [
          (label: 'Missed', body: MissedOpportunitiesScreen(showChrome: false)),
        ],
      ),
    );

    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.text('Missed opportunities'),
      findsNothing,
      reason: 'the embedded screen must not render its own title',
    );
  });

  testWidgets('it still renders its own chrome when reached as a standalone route', (tester) async {
    // The old routes were kept working, not just kept compiling.
    await _pump(tester, const MissedOpportunitiesScreen());

    expect(find.text('Missed opportunities'), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('switching tab swaps the body', (tester) async {
    await _pump(
      tester,
      const GroupedInsightScreen(
        title: 'Rewards',
        tabs: [
          (label: 'This month', body: MonthlySavingsScreen()),
          (label: 'By card', body: PortfolioAuditScreen()),
        ],
      ),
    );

    await tester.tap(find.text('By card'));
    await tester.pumpAndSettle();
    expect(find.byType(PortfolioAuditScreen), findsOneWidget);
  });
}
