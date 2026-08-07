import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay/features/home/home_context_line.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeNearbyRepo implements NearbyMerchantsRepository {
  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  }) async {
    return const [];
  }
}

void main() {
  testWidgets('shows a single-line fallback when the location flow cannot complete in a test host', (tester) async {
    // Geolocator has no platform implementation under flutter_test, so this
    // exercises the catch-all noPermission/offlineOrError branch — the
    // meaningful assertion is that SOME single-line context text renders,
    // never a blank/crashed widget, since the exact fallback text is
    // host-dependent (see nearby_merchants_screen.dart's own PROGRESS.md
    // note that geolocation is unverified on a real device in this sandbox).
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nearbyMerchantsRepositoryProvider.overrideWithValue(_FakeNearbyRepo())],
        child: const MaterialApp(home: Scaffold(body: HomeContextLine())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('the context line is tappable and meets the 48dp minimum touch target', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [nearbyMerchantsRepositoryProvider.overrideWithValue(_FakeNearbyRepo())],
        child: const MaterialApp(home: Scaffold(body: HomeContextLine())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final inkWellFinder = find.byType(InkWell);
    expect(inkWellFinder, findsOneWidget);

    final size = tester.getSize(inkWellFinder);
    expect(size.height, greaterThanOrEqualTo(48));

    // Tapping re-triggers the one-shot location read without throwing.
    await tester.tap(inkWellFinder);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(Text), findsOneWidget);
  });
}
