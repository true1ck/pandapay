import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/edit_card_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _RecordingUserCardsRepository implements UserCardsRepository {
  Map<String, dynamic>? lastUpdateArgs;
  bool archived = false;
  String? defaultedId;

  @override
  Future<void> updateCard(
    String userCardId, {
    String? nickname,
    double? creditLimitInr,
    int? statementDay,
    int? dueDay,
    double? pointsBalance,
    AutopayMode? autopayMode,
  }) async {
    lastUpdateArgs = {
      'userCardId': userCardId,
      'nickname': nickname,
      'creditLimitInr': creditLimitInr,
      'statementDay': statementDay,
      'dueDay': dueDay,
      'pointsBalance': pointsBalance,
      'autopayMode': autopayMode,
    };
  }

  @override
  Future<void> archiveCard(String userCardId) async => archived = true;

  @override
  Future<void> setDefaultCard(String userCardId) async => defaultedId = userCardId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fails every call the way a real HTTP client would offline, so the
/// screen's offline-queue fallback paths actually run. Genuinely `async`
/// (a real rejected Future, not a synchronous throw) to match how an actual
/// HTTP client fails — a synchronous throw from a non-async method skips
/// the microtask/event-loop turn a real network failure always has, which
/// matters here because it changes when GoRouter's own state is read.
class _OfflineUserCardsRepository implements UserCardsRepository {
  @override
  Future<void> updateCard(
    String userCardId, {
    String? nickname,
    double? creditLimitInr,
    int? statementDay,
    int? dueDay,
    double? pointsBalance,
    AutopayMode? autopayMode,
  }) async {
    throw Exception('simulated offline failure');
  }

  @override
  Future<void> archiveCard(String userCardId) async {
    throw Exception('simulated offline failure');
  }

  @override
  Future<void> setDefaultCard(String userCardId) async {
    throw Exception('simulated offline failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  required _RecordingUserCardsRepository repo,
}) async {
  final router = GoRouter(
    initialLocation: '/edit',
    routes: [
      GoRoute(path: '/edit', builder: (context, state) => const EditCardScreen(userCardId: 'uc1')),
      GoRoute(path: '/back', builder: (context, state) => const Scaffold(body: Text('back home'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
        userCardsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// Forces isOnlineProvider to initialize and settle before anything reads
/// it on demand inside a catch block — it's otherwise never ref.watch()'d
/// by the widget tree, so nothing else would start Riverpod listening to
/// the overridden stream before then, and it would still read
/// AsyncLoading() at tap time (a test-timing issue, not a real behavior
/// difference).
class _WarmIsOnline extends ConsumerWidget {
  final Widget child;
  const _WarmIsOnline({required this.child});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(isOnlineProvider);
    return child;
  }
}

/// Real navigation to EditCardScreen is always a PUSH from another screen
/// (Wallet, Card Detail — see my_cards_screen.dart/router.dart) — never the
/// app's own initial route. `_pump` above puts EditCardScreen directly at
/// `initialLocation`, which happens to still allow `context.pop()` to
/// succeed today, but is not what real navigation looks like and isn't a
/// premise worth relying on for a second call site. This router instead
/// starts at a real placeholder `/home` and pushes to `/edit`, so there's
/// a genuine prior route on the stack for these offline tests to pop back
/// to, matching the app's actual navigation shape.
Future<(GoRouter, SyncQueue)> _pumpOffline(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
}) async {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (context, state) => const Scaffold(body: Text('home'))),
      GoRoute(
        path: '/edit',
        builder: (context, state) => const _WarmIsOnline(child: EditCardScreen(userCardId: 'uc1')),
      ),
    ],
  );
  final queue = SyncQueue(openInMemoryForTesting());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
        userCardsRepositoryProvider.overrideWithValue(_OfflineUserCardsRepository()),
        isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        syncQueueProvider.overrideWith((ref) async => queue),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  router.push('/edit');
  await tester.pumpAndSettle();
  return (router, queue);
}

void main() {
  testWidgets('pre-fills nickname and credit limit from the existing card', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      UserCard(
        id: 'uc1',
        cardProductId: 'p1',
        nickname: 'My Card',
        cardName: 'Test Card',
        isDefault: false,
        creditLimit: Money.fromRupees(50000),
      ),
    ];
    await _pump(tester, catalogue: [product], owned: owned, repo: _RecordingUserCardsRepository());

    expect(find.widgetWithText(TextField, 'Nickname'), findsOneWidget);
    final nicknameField = tester.widget<TextField>(find.widgetWithText(TextField, 'Nickname'));
    expect(nicknameField.controller!.text, 'My Card');
    final limitField = tester.widget<TextField>(find.widgetWithText(TextField, 'Credit limit (₹)'));
    expect(limitField.controller!.text, '50000');
  });

  testWidgets('Save sends the edited nickname to the repository and pops', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.enterText(find.widgetWithText(TextField, 'Nickname'), 'Renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastUpdateArgs?['userCardId'], 'uc1');
    expect(repo.lastUpdateArgs?['nickname'], 'Renamed');
  });

  testWidgets('Remove card confirms in a sheet before calling archiveCard', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.scrollUntilVisible(find.text('Remove card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Remove card'));
    await tester.pumpAndSettle();

    // Design 23: destructive actions confirm in a sheet — nothing has been
    // archived yet at this point.
    expect(repo.archived, isFalse);
    expect(find.text('Remove this card?'), findsOneWidget);

    // 'Remove card' now matches both the screen button and the sheet's own
    // confirm button, so scope to the one inside the sheet.
    await tester.tap(find.widgetWithText(FilledButton, 'Remove card'));
    await tester.pumpAndSettle();

    expect(repo.archived, isTrue);
  });

  testWidgets('cancelling the remove sheet leaves the card alone', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.scrollUntilVisible(find.text('Remove card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Remove card'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(repo.archived, isFalse);
  });

  testWidgets('Set as default card calls setDefaultCard', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final repo = _RecordingUserCardsRepository();
    await _pump(
      tester,
      catalogue: [product],
      owned: [const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false)],
      repo: repo,
    );

    await tester.scrollUntilVisible(find.text('Set as default card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Set as default card'));
    await tester.pumpAndSettle();

    expect(repo.defaultedId, 'uc1');
  });

  testWidgets('a card that is already default shows a state row, not the action', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    await _pump(
      tester,
      catalogue: [product],
      owned: [const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: true)],
      repo: _RecordingUserCardsRepository(),
    );

    await tester.scrollUntilVisible(
      find.text('This is your default card'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Set as default card'), findsNothing);
  });

  testWidgets('Save while offline queues nickname/credit-limit edits instead of failing outright', (
    tester,
  ) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final (router, queue) = await _pumpOffline(tester, catalogue: [product], owned: owned);

    await tester.enterText(find.widgetWithText(TextField, 'Nickname'), 'Renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Saved offline — will sync when you reconnect.'), findsOneWidget);
    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entity, 'user_cards');
    expect(pending.single.entityId, 'uc1');
    expect(pending.single.payload['nickname'], 'Renamed');
    // Points balance was never in this test's payload since it wasn't
    // touched, and must never appear even as a null placeholder — the
    // server-side allowlist doesn't recognize it at all for this entity.
    expect(pending.single.payload.containsKey('pointsBalance'), isFalse);
  });

  testWidgets(
    'Save while offline warns explicitly when the points balance also changed, since that field cannot be queued',
    (tester) async {
      final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
      final owned = [
        UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          cardName: 'Test Card',
          isDefault: false,
          totalPointsEarned: 100,
        ),
      ];
      final (_, queue) = await _pumpOffline(tester, catalogue: [product], owned: owned);

      await tester.enterText(find.widgetWithText(TextField, 'Current points balance'), '500');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Points balance needs a live connection'), findsOneWidget);
      // The rest of the edit (even though unchanged here) still queues —
      // only the points balance itself is excluded.
      expect(queue.pending(), hasLength(1));
    },
  );

  testWidgets('Remove card while offline queues is_archived instead of failing outright', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'Old', cardName: 'Test Card', isDefault: false),
    ];
    final (_, queue) = await _pumpOffline(tester, catalogue: [product], owned: owned);

    await tester.scrollUntilVisible(find.text('Remove card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Remove card'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove card'));
    await tester.pumpAndSettle();

    expect(find.text('Removed offline — will sync when you reconnect.'), findsOneWidget);
    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entity, 'user_cards');
    expect(pending.single.entityId, 'uc1');
    expect(pending.single.payload, {'is_archived': true});
  });

  testWidgets('Set as default while offline asks for connectivity rather than queuing an unsafe change', (
    tester,
  ) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false),
    ];
    final (_, queue) = await _pumpOffline(tester, catalogue: [product], owned: owned);

    await tester.scrollUntilVisible(
      find.text('Set as default card'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Set as default card'));
    await tester.pumpAndSettle();

    expect(find.textContaining('needs an internet connection'), findsOneWidget);
    // Deliberately nothing queued — see the source comment: queuing just
    // this row's is_default=true could leave two cards flagged default.
    expect(queue.pending(), isEmpty);
  });
}
