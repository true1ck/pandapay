import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/sync_status/sync_status_banner.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';

// History: the owner removed Home's own offline banner on 2026-10-18 (commit
// 37f7d9c7), and the first two tests keep HomeScreen on its own free of the
// legacy "You're offline" text. Decision D2 (2026-11-14) then asked for a NEW,
// small strip at the top of the whole app (features/sync_status/). It is
// mounted above the Navigator by main.dart, not by any screen, and uses
// different words, so Home still renders no connectivity text of its own.
void main() {
  testWidgets('Home does not show the legacy connectivity banner offline', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
          isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining("You're offline"), findsNothing);
  });

  testWidgets('shows no banner when isOnlineProvider reads true', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
          isOnlineProvider.overrideWith((ref) => Stream.value(true)),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining("You're offline"), findsNothing);
  });

  testWidgets('the app-wide strip sits above Home; Home still shows no legacy '
      'banner of its own', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
          isOnlineProvider.overrideWith((ref) => Stream.value(false)),
          syncStatusSummaryProvider.overrideWithValue(
            const SyncStatusSummary(mode: SyncStatusMode.offline),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => SyncStatusBanner(child: child),
          home: const Scaffold(body: HomeScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Offline mode · changes saved on this phone'), findsOneWidget);
    expect(find.textContaining("You're offline"), findsNothing);
    // The strip is not part of HomeScreen.
    expect(
      find.descendant(
        of: find.byType(HomeScreen),
        matching: find.text('Offline mode · changes saved on this phone'),
      ),
      findsNothing,
    );
  });
}
