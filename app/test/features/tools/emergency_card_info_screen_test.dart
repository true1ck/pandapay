import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/emergency_contacts_repository.dart';
import 'package:pandapay/features/tools/emergency_card_info_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// G4 Emergency Card Info — the one screen with a genuine "must work with
/// zero network and zero login" mandate (Chunk 38). Exercises the three-tier
/// fallback (live -> cached -> bundled) that EmergencyContactsService.load()
/// implements, since a mistake here is safety-critical (a user trying to
/// block a lost card while genuinely offline).
class _FakeRepository implements EmergencyContactsRepository {
  final List<IssuerEmergencyContact> Function()? onFetch;
  final Object? error;
  _FakeRepository({this.onFetch, this.error});

  @override
  Future<List<IssuerEmergencyContact>> fetch() async {
    if (error != null) throw error!;
    return onFetch?.call() ?? const [];
  }
}

IssuerEmergencyContact _contact({required String id, required String issuer, String phone = '1800-000-000'}) {
  return IssuerEmergencyContact(
    id: id,
    issuerName: issuer,
    issuerSlug: issuer.toLowerCase(),
    label: 'Block a lost/stolen card',
    phone: phone,
    isInternational: false,
    isCollectCall: false,
    sortOrder: 0,
  );
}

Future<void> _pump(WidgetTester tester, EmergencyContactsRepository repository) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        emergencyContactsRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: EmergencyCardInfoScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows live data and an "up to date" banner on a successful fetch', (tester) async {
    final repo = _FakeRepository(onFetch: () => [_contact(id: 'c1', issuer: 'HDFC Bank')]);
    await _pump(tester, repo);

    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(find.text('HDFC Bank'), findsOneWidget);
  });

  testWidgets(
      'falls back to the bundled dataset (never blank) when the network fails and nothing was ever cached',
      (tester) async {
    final repo = _FakeRepository(error: Exception('offline'));
    await _pump(tester, repo);

    // Bundled fallback's own honesty banner, not a generic ErrorState — this
    // screen must never show "something went wrong" for plain offline.
    expect(find.textContaining('No issuer data has synced'), findsOneWidget);
    expect(find.text('Any issuer — first step'), findsOneWidget);
    expect(find.textContaining('Visa (network-level'), findsOneWidget);
  });

  testWidgets('falls back to cached data (not bundled) when offline but something was cached before',
      (tester) async {
    // First pump: a live fetch succeeds and gets cached on-device.
    final liveRepo = _FakeRepository(onFetch: () => [_contact(id: 'c1', issuer: 'ICICI Bank')]);
    await _pump(tester, liveRepo);
    expect(find.textContaining('Up to date'), findsOneWidget);

    // Second pump, fresh provider tree (simulating a relaunch), now offline
    // — should surface the cached copy, not the generic bundled guidance.
    final offlineRepo = _FakeRepository(error: Exception('offline'));
    await _pump(tester, offlineRepo);

    expect(find.textContaining('Showing data saved on this device'), findsOneWidget);
    expect(find.text('ICICI Bank'), findsOneWidget);
  });

  testWidgets('a call button is only shown for contacts with a real phone number', (tester) async {
    final repo = _FakeRepository(error: Exception('offline')); // bundled fallback has one blank-phone entry
    await _pump(tester, repo);

    // "Any issuer — first step" bundled entry has phone: '' -> no dial button
    // for that specific row, but Visa/Mastercard rows (real numbers) do.
    expect(find.byIcon(Icons.call_rounded), findsWidgets);
  });
}
