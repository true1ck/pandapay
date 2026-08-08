import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/app_status_repository.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/system/forced_upgrade_screen.dart';
import 'package:pandapay/features/system/maintenance_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — forced upgrade /
/// maintenance mode redirect guard in router.dart.
class _EmptyCatalogueRepository implements CatalogueRepository {
  @override
  Future<List<CardProduct>> fetchCatalogue() async => const [];
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pumpApp(WidgetTester tester, {required List<Override> extraOverrides}) async {
  SharedPreferences.setMockInitialValues({'pandapay_app.onboarding_complete_v1': true});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_EmptyCatalogueRepository()),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
        sessionInitProvider.overrideWith((ref) async {}),
        ...extraOverrides,
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
  testWidgets('maintenance_mode blocks the app with MaintenanceScreen', (tester) async {
    await _pumpApp(
      tester,
      extraOverrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(minSupportedVersion: '1.0.0', maintenanceMode: true),
        ),
      ],
    );

    expect(find.byType(MaintenanceScreen), findsOneWidget);
    expect(find.text('PandaPay — Home'), findsNothing);
  });

  testWidgets('a too-old app version blocks the app with ForcedUpgradeScreen', (tester) async {
    await _pumpApp(
      tester,
      extraOverrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(minSupportedVersion: '999.0.0', maintenanceMode: false),
        ),
        appVersionProvider.overrideWith((ref) async => '1.0.0'),
      ],
    );

    expect(find.byType(ForcedUpgradeScreen), findsOneWidget);
    expect(find.text('PandaPay — Home'), findsNothing);
  });

  testWidgets('a current-enough app version and no maintenance mode reaches Home normally', (tester) async {
    await _pumpApp(
      tester,
      extraOverrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(minSupportedVersion: '1.0.0', maintenanceMode: false),
        ),
        appVersionProvider.overrideWith((ref) async => '1.0.0'),
      ],
    );

    expect(find.text('PandaPay — Home'), findsOneWidget);
    expect(find.byType(MaintenanceScreen), findsNothing);
    expect(find.byType(ForcedUpgradeScreen), findsNothing);
  });

  testWidgets('a failed status check (fails open) does not block the app', (tester) async {
    await _pumpApp(
      tester,
      extraOverrides: [
        appStatusProvider.overrideWith((ref) async => null),
      ],
    );

    expect(find.text('PandaPay — Home'), findsOneWidget);
    expect(find.byType(MaintenanceScreen), findsNothing);
    expect(find.byType(ForcedUpgradeScreen), findsNothing);
  });
}
