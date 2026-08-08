import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/insights/caps_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task 7. Insights Hub is the single entry point to Caps, Milestones,
/// Billing Float and Activity — no Utilization tile yet (Task 9's
/// credit_limit_inr migration hasn't landed, and a tile pointing at a
/// screen that can't render anything real would be worse than no tile).
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'pandapay_app.onboarding_complete_v1': true});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(const [])),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
        userCardsProvider.overrideWith((ref) async => const []),
        sessionInitProvider.overrideWith((ref) async {}),
      ],
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: ref.watch(goRouterProvider),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the Credit Utilization tile alongside the other insight tiles', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Insights')));
    await tester.pumpAndSettle();

    expect(find.text('Caps & Limits'), findsOneWidget);
    expect(find.text('Milestones'), findsOneWidget);
    expect(find.text('Billing Float'), findsOneWidget);

    // The hub has grown to 15 tiles across Groups E/F/G — later tiles sit
    // further down the grid than the fixed test surface shows without
    // scrolling, so each needs an explicit scroll rather than assuming
    // it's already laid out in the initial viewport.
    await tester.scrollUntilVisible(find.text('Credit Utilization'), 200, scrollable: find.byType(Scrollable));
    expect(find.text('Credit Utilization'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('All Activity'), 200, scrollable: find.byType(Scrollable));
    expect(find.text('All Activity'), findsOneWidget);
  });

  testWidgets('tapping Caps & Limits pushes CapsScreen with a back button', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Insights')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Caps & Limits'));
    await tester.pumpAndSettle();

    expect(find.byType(CapsScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });
}
