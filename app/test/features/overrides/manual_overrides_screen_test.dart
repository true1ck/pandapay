import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/overrides/manual_overrides_screen.dart';

/// Fails every call the way a real HTTP client would offline, so the
/// screen's offline-queue fallback path actually runs instead of the
/// happy path `_FakeCardOverridesRepository` below exercises.
class _OfflineCardOverridesRepository extends CardOverridesRepository {
  final List<CardOverride> overrides;
  _OfflineCardOverridesRepository(this.overrides) : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<List<CardOverride>> fetchOverrides() async => overrides;

  @override
  Future<void> updateOverride(String id, {bool? isEnabled, String? reasonNote, String? userCardId}) {
    throw Exception('simulated offline failure');
  }
}

/// In-memory stand-in for CardOverridesRepository so the edit/delete flows
/// can be exercised end-to-end (widget tap -> repository call -> provider
/// invalidate -> refetched list) without a real HTTP client. Records every
/// call so tests can assert on exactly which fields a PATCH carried.
class _FakeCardOverridesRepository extends CardOverridesRepository {
  List<CardOverride> overrides;
  final List<String> calls = [];

  _FakeCardOverridesRepository(this.overrides) : super(apiBaseUrl: 'http://localhost', accessToken: 't');

  @override
  Future<List<CardOverride>> fetchOverrides() async => overrides;

  @override
  Future<void> delete(String id) async {
    calls.add('delete:$id');
    overrides = overrides.where((o) => o.id != id).toList();
  }

  @override
  Future<void> updateOverride(String id, {bool? isEnabled, String? reasonNote, String? userCardId}) async {
    calls.add('update:$id:isEnabled=$isEnabled:reasonNote=$reasonNote:userCardId=$userCardId');
    overrides = overrides.map((o) {
      if (o.id != id) return o;
      return CardOverride(
        id: o.id,
        userCardId: userCardId ?? o.userCardId,
        scope: o.scope,
        vpa: o.vpa,
        merchantName: o.merchantName,
        categoryId: o.categoryId,
        categoryName: o.categoryName,
        reasonNote: reasonNote ?? o.reasonNote,
        isEnabled: isEnabled ?? o.isEnabled,
        createdAt: o.createdAt,
        cardName: userCardId == 'uc2' ? 'ICICI Amazon Pay' : o.cardName,
        cardNickname: o.cardNickname,
      );
    }).toList();
  }
}

void main() {
  testWidgets('shows the empty state when there are no overrides', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => const [])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No overrides yet'), findsOneWidget);
  });

  testWidgets('shows one tile per override with its target and card', (tester) async {
    final override = CardOverride(
      id: 'o1',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Fuel'), findsOneWidget);
    expect(find.textContaining('HDFC Millennia'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('shows the loading state while overrides are fetching', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) => Completer<List<CardOverride>>().future)],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows the error state with a retry action on failure', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => throw StateError('boom'))],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('disabled override shows a Disabled pill and an Enable action', (tester) async {
    final override = CardOverride(
      id: 'o2',
      userCardId: 'uc1',
      scope: OverrideScope.merchantName,
      merchantName: 'Amazon',
      isEnabled: false,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'ICICI Amazon Pay',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Enable'), findsOneWidget);
  });

  testWidgets('tapping Delete opens a confirmation dialog before removing anything', (tester) async {
    final override = CardOverride(
      id: 'o3',
      userCardId: 'uc1',
      scope: OverrideScope.vpa,
      vpa: 'shop@upi',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesProvider.overrideWith((ref) async => [override])],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this override?'), findsOneWidget);
    // The tile itself is still present — nothing was deleted without
    // confirming, since cardOverridesRepositoryProvider isn't overridden
    // (accessTokenProvider defaults to null, so repo is null) and no repo
    // call could have succeeded anyway.
    expect(find.text('VPA: shop@upi'), findsOneWidget);
  });

  testWidgets('confirming Delete actually calls the repository and removes the tile', (tester) async {
    final override = CardOverride(
      id: 'o4',
      userCardId: 'uc1',
      scope: OverrideScope.vpa,
      vpa: 'shop@upi',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    final fakeRepo = _FakeCardOverridesRepository([override]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardOverridesRepositoryProvider.overrideWithValue(fakeRepo)],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('VPA: shop@upi'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, 'Delete'),
    ));
    await tester.pumpAndSettle();

    expect(fakeRepo.calls, ['delete:o4']);
    expect(find.text('VPA: shop@upi'), findsNothing);
    expect(find.text('No overrides yet'), findsOneWidget);
  });

  testWidgets('editing an override reassigns the card and note via updateOverride, not delete+recreate', (tester) async {
    final override = CardOverride(
      id: 'o5',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      reasonNote: 'old note',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    final fakeRepo = _FakeCardOverridesRepository([override]);
    const userCards = [
      UserCard(id: 'uc1', cardProductId: 'cp1', cardName: 'HDFC Millennia', isDefault: true),
      UserCard(id: 'uc2', cardProductId: 'cp2', cardName: 'ICICI Amazon Pay', isDefault: false),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cardOverridesRepositoryProvider.overrideWithValue(fakeRepo),
          userCardsProvider.overrideWith((ref) async => userCards),
        ],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Edit override'), findsOneWidget);
    // Scope-defining fields must not be editable here.
    expect(find.text('Category'), findsNothing);
    expect(find.byType(SegmentedButton<OverrideScope>), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'new note');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(fakeRepo.calls, ['update:o5:isEnabled=null:reasonNote=new note:userCardId=uc1']);
    expect(find.textContaining('new note'), findsOneWidget);
    expect(find.text('Edit override'), findsNothing); // sheet closed
  });

  testWidgets(
      'editing an override whose card was archived (absent from userCardsProvider) does not crash and shows no card selected',
      (tester) async {
    // GET /card-overrides doesn't exclude overrides pointing at archived
    // cards, unlike GET /user-cards — so this override's userCardId ('uc1')
    // legitimately doesn't appear in the current userCardsProvider list.
    // Before the fix, DropdownButtonFormField's `initialValue: uc1` with no
    // matching item in `items` throws a debug assertion.
    final override = CardOverride(
      id: 'o6',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'Archived Card',
    );
    final fakeRepo = _FakeCardOverridesRepository([override]);
    const userCards = [
      // Note: no 'uc1' here — that card has been archived.
      UserCard(id: 'uc2', cardProductId: 'cp2', cardName: 'ICICI Amazon Pay', isDefault: false),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cardOverridesRepositoryProvider.overrideWithValue(fakeRepo),
          userCardsProvider.overrideWith((ref) async => userCards),
        ],
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // No assertion/exception thrown — the sheet opened successfully.
    expect(tester.takeException(), isNull);
    expect(find.text('Edit override'), findsOneWidget);

    // No card selected (fell back to null) -> Save changes stays disabled.
    final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save changes'));
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('toggling enabled while offline queues the change instead of failing outright', (tester) async {
    final override = CardOverride(
      id: 'o7',
      userCardId: 'uc1',
      scope: OverrideScope.vpa,
      vpa: 'shop@upi',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    final offlineRepo = _OfflineCardOverridesRepository([override]);
    final queue = SyncQueue(openInMemoryForTesting());
    final container = ProviderContainer(
      overrides: [
        cardOverridesRepositoryProvider.overrideWithValue(offlineRepo),
        isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        syncQueueProvider.overrideWith((ref) async => queue),
      ],
    );
    addTearDown(container.dispose);
    // isOnlineProvider is only ever ref.read() on demand (inside _toggle's
    // catch block), never ref.watch()'d by anything in the widget tree — so
    // nothing forces Riverpod to start listening to the overridden stream
    // until then. Reading it here first, and awaiting its first value,
    // ensures it has already settled to AsyncData(false) before the tap
    // below, instead of still being AsyncLoading() at the moment _toggle
    // reads it (which would make `offline` false and this test flaky/wrong
    // for a timing reason that has nothing to do with the code under test).
    container.read(isOnlineProvider);
    await container.read(isOnlineProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disable')); // currently enabled, so the action label is "Disable"
    await tester.pumpAndSettle();

    expect(find.text('Saved offline — will sync when you reconnect.'), findsOneWidget);
    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entity, 'card_overrides');
    expect(pending.single.entityId, 'o7');
    expect(pending.single.payload, {'is_enabled': false});
  });

  testWidgets('editing an override while offline queues the change instead of failing outright', (tester) async {
    final override = CardOverride(
      id: 'o8',
      userCardId: 'uc1',
      scope: OverrideScope.category,
      categoryId: 'cat1',
      categoryName: 'Fuel',
      reasonNote: 'old note',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'HDFC Millennia',
    );
    final offlineRepo = _OfflineCardOverridesRepository([override]);
    final queue = SyncQueue(openInMemoryForTesting());
    const userCards = [
      UserCard(id: 'uc1', cardProductId: 'cp1', cardName: 'HDFC Millennia', isDefault: true),
    ];
    final container = ProviderContainer(
      overrides: [
        cardOverridesRepositoryProvider.overrideWithValue(offlineRepo),
        userCardsProvider.overrideWith((ref) async => userCards),
        isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        syncQueueProvider.overrideWith((ref) async => queue),
      ],
    );
    addTearDown(container.dispose);
    // See the toggle test above for why isOnlineProvider needs to be forced
    // to settle before anything reads it on demand.
    container.read(isOnlineProvider);
    await container.read(isOnlineProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ManualOverridesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'new note');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Saved offline — will sync when you reconnect.'), findsOneWidget);
    expect(find.text('Edit override'), findsNothing); // sheet closed, same as the online-success case
    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entity, 'card_overrides');
    expect(pending.single.entityId, 'o8');
    expect(pending.single.payload, {'user_card_id': 'uc1', 'reason_note': 'new note'});
  });
}
