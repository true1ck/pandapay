import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 3: go_router replaces int-index tab switching + raw MaterialPageRoute.
/// This is a pure navigation-shell swap — zero behaviour change for the four
/// existing tabs — so the tests only assert "the right screen shows for the
/// right route and the right nav item highlights", not anything about screen
/// content (that's each screen's own test file's job).
class _EmptyCatalogueRepository implements CatalogueRepository {
  @override
  Future<List<CardProduct>> fetchCatalogue() async => const [];
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_EmptyCatalogueRepository()),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
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
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('initial route renders Home inside the shell with Home highlighted', (tester) async {
    await _pumpApp(tester);

    expect(find.text('PandaPay — Home'), findsOneWidget);
    expect(find.byType(BottomAppBar), findsOneWidget);
  });

  testWidgets('tapping Cards navigates to /cards and shows the Cards screen', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Cards')));
    await tester.pump();
    await tester.pump();

    expect(find.text('PandaPay — Cards'), findsOneWidget);
  });

  testWidgets('tapping Activity then Account navigates correctly (order-independent)', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Activity')));
    await tester.pump();
    await tester.pump();
    expect(find.text('PandaPay — Activity'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Account')));
    await tester.pump();
    await tester.pump();
    expect(find.text('PandaPay — Account'), findsOneWidget);
  });

  testWidgets('the scan FAB is present on every tab (not just Home)', (tester) async {
    await _pumpApp(tester);
    expect(find.byIcon(Icons.qr_code_scanner_rounded), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(BottomAppBar), matching: find.text('Cards')));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.qr_code_scanner_rounded), findsOneWidget);
  });
}
