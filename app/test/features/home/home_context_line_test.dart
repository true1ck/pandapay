import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
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

/// A fake `GeolocatorPlatform` that reports location services enabled and
/// permission stuck at `denied` (Android's "denied but not 'don't ask
/// again'" state — exactly the state where a real device would show the OS
/// permission dialog on `requestPermission()`), and counts how many times
/// each method is called. Installed via `GeolocatorPlatform.instance =`
/// so `HomeContextLine`'s calls through `package:geolocator` route here
/// instead of the (platform-less, exception-throwing) method channel —
/// letting the test assert directly on whether `requestPermission()` — the
/// one call that can pop a real system dialog — was ever invoked.
class _DeniedGeolocator extends GeolocatorPlatform {
  int checkPermissionCalls = 0;
  int requestPermissionCalls = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async {
    checkPermissionCalls++;
    return LocationPermission.denied;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls++;
    // Simulating a real device: the user has not granted it.
    return LocationPermission.denied;
  }

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    // Not reached in the denied-permission scenarios below, but implemented
    // so a future "granted" test doesn't have to add a second fake.
    return Future.value(
      Position(
        latitude: 19.1197,
        longitude: 72.9051,
        timestamp: DateTime(2026, 8, 8),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
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

  testWidgets(
      'an automatic mount never calls requestPermission() — even across repeated '
      'remounts simulating Home -> other tab -> Home navigation', (tester) async {
    final originalGeolocator = GeolocatorPlatform.instance;
    final fakeGeolocator = _DeniedGeolocator();
    GeolocatorPlatform.instance = fakeGeolocator;
    addTearDown(() => GeolocatorPlatform.instance = originalGeolocator);

    Widget host() => ProviderScope(
          overrides: [nearbyMerchantsRepositoryProvider.overrideWithValue(_FakeNearbyRepo())],
          child: const MaterialApp(home: Scaffold(body: HomeContextLine())),
        );

    // First mount (e.g. first time Home loads this session).
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Simulate leaving and returning to the Home tab: since Home's route is
    // a plain ShellRoute/GoRoute (not StatefulShellRoute.indexedStack — see
    // app/lib/app/router.dart), the widget is disposed and rebuilt on every
    // return, exactly like pumping a fresh widget tree here.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Three automatic mounts, permission stuck at `denied` the whole time —
    // checkPermission() (read-only, never surfaces a dialog) fires each
    // time, but requestPermission() — the call that can pop a real system
    // permission dialog — must never fire on an automatic mount. This is
    // the exact regression the review flagged: without the fix, each mount
    // would call requestPermission() and re-surface the OS dialog on
    // ordinary tab navigation.
    expect(fakeGeolocator.checkPermissionCalls, 3);
    expect(fakeGeolocator.requestPermissionCalls, 0);
  });

  testWidgets('an explicit tap is allowed to call requestPermission() once permission is denied',
      (tester) async {
    final originalGeolocator = GeolocatorPlatform.instance;
    final fakeGeolocator = _DeniedGeolocator();
    GeolocatorPlatform.instance = fakeGeolocator;
    addTearDown(() => GeolocatorPlatform.instance = originalGeolocator);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [nearbyMerchantsRepositoryProvider.overrideWithValue(_FakeNearbyRepo())],
        child: const MaterialApp(home: Scaffold(body: HomeContextLine())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Automatic mount: no prompt yet.
    expect(fakeGeolocator.requestPermissionCalls, 0);

    // User explicitly taps the context line to correct/retry location —
    // this IS allowed to prompt, matching nearby_merchants_screen.dart's
    // own button-triggered flow.
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(fakeGeolocator.requestPermissionCalls, 1);
  });
}
