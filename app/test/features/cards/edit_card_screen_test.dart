import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local_first/local_first_cards.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
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
    String? last4,
  }) async {
    lastUpdateArgs = {
      'userCardId': userCardId,
      'nickname': nickname,
      'last4': last4,
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
  Future<void> setDefaultCard(String userCardId) async =>
      defaultedId = userCardId;

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
    String? last4,
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
      GoRoute(
        path: '/edit',
        builder: (context, state) => const EditCardScreen(userCardId: 'uc1'),
      ),
      GoRoute(
        path: '/back',
        builder: (context, state) => const Scaffold(body: Text('back home')),
      ),
      GoRoute(
        path: '/cards',
        builder: (context, state) => const Scaffold(body: Text('Wallet')),
      ),
    ],
  );
  final testDb = openInMemoryForTesting();
  final cache = ResponseCache(testDb);
  final store = cache.financialStore..replaceCards('legacy', owned);
  addTearDown(store.dispose);
  _lastStore = store;
  _lastCommands = CommandOutbox(testDb, namespace: 'legacy');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(
          _FakeCatalogueRepository(catalogue),
        ),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
        userCardsRepositoryProvider.overrideWithValue(repo),
        // Saves go to the phone first: this is where they are kept.
        responseCacheProvider.overrideWith((ref) async => cache),
        commandOutboxProvider.overrideWith((ref) async => _lastCommands!),
        syncQueueProvider.overrideWith((ref) async => SyncQueue(testDb)),
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
CommandOutbox? _lastCommands;
FinancialStore? _lastStore;
_RecordingUserCardsRepository? _lastOnlineRepo;

/// [online] true: the server answers (the recording repository). The screen
/// must still save on the phone first and never call it.
Future<(GoRouter, SyncQueue)> _pumpOffline(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  bool online = false,
}) async {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (context, state) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: '/edit',
        builder: (context, state) =>
            const _WarmIsOnline(child: EditCardScreen(userCardId: 'uc1')),
      ),
    ],
  );
  final testDb = openInMemoryForTesting();
  final queue = SyncQueue(testDb);
  final commands = CommandOutbox(testDb, namespace: 'legacy');
  _lastCommands = commands;
  final cache = ResponseCache(testDb);
  final store = cache.financialStore..replaceCards('legacy', owned);
  _lastStore = store;
  _lastOnlineRepo = online ? _RecordingUserCardsRepository() : null;
  addTearDown(store.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(
          _FakeCatalogueRepository(catalogue),
        ),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
        userCardsRepositoryProvider.overrideWithValue(
          online ? _lastOnlineRepo! : _OfflineUserCardsRepository(),
        ),
        responseCacheProvider.overrideWith((ref) async => cache),
        isOnlineProvider.overrideWith((ref) => Stream.value(online)),
        syncQueueProvider.overrideWith((ref) async => queue),
        commandOutboxProvider.overrideWith((ref) async => commands),
        localFirstCardsProvider.overrideWith(
          (ref) async =>
              LocalFirstCards(store: store, queue: queue, namespace: 'legacy'),
        ),
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
  testWidgets('pre-fills nickname and credit limit from the existing card', (
    tester,
  ) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
    );
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
    await _pump(
      tester,
      catalogue: [product],
      owned: owned,
      repo: _RecordingUserCardsRepository(),
    );

    expect(find.widgetWithText(TextField, 'Nickname'), findsOneWidget);
    final nicknameField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Nickname'),
    );
    expect(nicknameField.controller!.text, 'My Card');
    await tester.scrollUntilVisible(
      find.text('Credit limit (₹)'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final limitField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Credit limit (₹)'),
    );
    expect(limitField.controller!.text, '50000');
  });

  testWidgets(
    'shows catalogue details without asking the user to re-enter them',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
        issuerName: 'Test Bank',
        annualFeeInr: Money.fromRupees(999),
        joiningFeeInr: Money.fromRupees(499),
        verifiedAt: DateTime(2026, 10, 1),
        rewardRules: [
          const RewardRule(id: 'r1', unit: RewardUnit.cashbackPercent, rate: 1),
        ],
        capRules: [
          const CapRule(
            id: 'cap1',
            label: 'Monthly cap',
            capValue: Money.fromPaise(100000),
            measure: CapMeasure.spendAmount,
            period: CapPeriod.calendarMonth,
          ),
        ],
        milestoneRules: [
          const MilestoneRule(
            id: 'm1',
            label: 'Welcome milestone',
            thresholdSpend: Money.fromPaise(1000000),
            rewardValue: Money.fromPaise(10000),
          ),
        ],
        benefits: [
          const CardBenefit(
            id: 'b1',
            kind: BenefitKind.loungeDomestic,
            label: 'Domestic lounge access',
          ),
        ],
      );
      await _pump(
        tester,
        catalogue: [product],
        owned: [
          const UserCard(
            id: 'uc1',
            cardProductId: 'p1',
            cardName: 'Test Card',
            isDefault: false,
            annualFeeOverride: Money.zero(),
            autopayMode: AutopayMode.full,
          ),
        ],
        repo: _RecordingUserCardsRepository(),
      );

      expect(find.text('Test Bank · RuPay'), findsOneWidget);
      expect(find.text('Your annual fee'), findsOneWidget);
      expect(find.text('Lifetime free'), findsOneWidget);
      expect(find.text('Joining fee'), findsOneWidget);
      expect(find.text('1 earning rules'), findsOneWidget);
      expect(find.text('1 caps · 1 milestones'), findsOneWidget);
      expect(find.text('1 benefits · 1 lounge'), findsOneWidget);
      expect(find.text('01/10/2026'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Autopay preference'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Full statement balance'), findsOneWidget);
    },
  );

  testWidgets('pre-fills current points balance, not lifetime points earned', (
    tester,
  ) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
    );
    final owned = [
      UserCard(
        id: 'uc1',
        cardProductId: 'p1',
        cardName: 'Test Card',
        isDefault: false,
        totalPointsEarned: 9122,
        pointsBalance: 2122,
      ),
    ];
    await _pump(
      tester,
      catalogue: [product],
      owned: owned,
      repo: _RecordingUserCardsRepository(),
    );

    await tester.scrollUntilVisible(
      find.text('Current points balance'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final pointsField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Current points balance'),
    );
    expect(pointsField.controller!.text, '2122');
  });

  testWidgets(
    'Save is local first: stored and queued at once, the server is not called',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      final owned = [
        const UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          nickname: 'Old',
          cardName: 'Test Card',
          isDefault: false,
        ),
      ];
      final (router, queue) = await _pumpOffline(
        tester,
        catalogue: [product],
        owned: owned,
        online: true,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Nickname'),
        'Renamed',
      );
      await tester.scrollUntilVisible(
        find.text('Save'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Closed, with no "offline" message because the phone is online.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/home',
      );
      expect(find.textContaining('Saved on this phone'), findsNothing);
      // Never waited on, never called: delivery is the outbox's job.
      expect(_lastOnlineRepo!.lastUpdateArgs, isNull);
      final patch = _lastCommands!.pendingOf({'card_fields_patch'}).single;
      expect(patch.target, 'uc1');
      expect(patch.payload['nickname'], 'Renamed');
      expect(queue.pending(), isEmpty, reason: 'the card PATCH route carries it');

      // The stored card already shows it, and an older server copy arriving
      // before delivery cannot flip it back.
      String? nickname() => _lastStore!
          .entities('legacy', 'cards')
          .singleWhere((c) => c['id'] == 'uc1')['nickname'] as String?;
      expect(nickname(), 'Renamed');
      _lastStore!.replaceCards('legacy', owned);
      expect(nickname(), 'Renamed');
    },
  );

  testWidgets('Remove card confirms in a sheet, then removes it at once and queues the archive', (
    tester,
  ) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
    );
    final owned = [
      const UserCard(
        id: 'uc1',
        cardProductId: 'p1',
        nickname: 'Old',
        cardName: 'Test Card',
        isDefault: false,
      ),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.scrollUntilVisible(
      find.text('Remove card'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
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

    // Local first: the server is not called during the tap; the outbox sends it.
    expect(repo.archived, isFalse);
    expect(_lastCommands!.pendingOf({'archive_card'}).single.target, 'uc1');
    expect(find.text('Wallet'), findsOneWidget);
    expect(find.textContaining('could not be found'), findsNothing);
  });

  testWidgets('cancelling the remove sheet leaves the card alone', (
    tester,
  ) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
    );
    final owned = [
      const UserCard(
        id: 'uc1',
        cardProductId: 'p1',
        nickname: 'Old',
        cardName: 'Test Card',
        isDefault: false,
      ),
    ];
    final repo = _RecordingUserCardsRepository();
    await _pump(tester, catalogue: [product], owned: owned, repo: repo);

    await tester.scrollUntilVisible(
      find.text('Remove card'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Remove card'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(repo.archived, isFalse);
  });

  testWidgets('Set as default card is saved first and queued for the server', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
    );
    final repo = _RecordingUserCardsRepository();
    await _pump(
      tester,
      catalogue: [product],
      owned: [
        const UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          cardName: 'Test Card',
          isDefault: false,
        ),
      ],
      repo: repo,
    );

    await tester.scrollUntilVisible(
      find.text('Set as default card'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Set as default card'));
    await tester.pumpAndSettle();

    expect(repo.defaultedId, isNull, reason: 'the outbox sends it, not the tap');
    expect(_lastCommands!.pendingOf({'set_default'}).single.target, 'uc1');
  });

  testWidgets(
    'a card that is already default shows a state row, not the action',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      await _pump(
        tester,
        catalogue: [product],
        owned: [
          const UserCard(
            id: 'uc1',
            cardProductId: 'p1',
            cardName: 'Test Card',
            isDefault: true,
          ),
        ],
        repo: _RecordingUserCardsRepository(),
      );

      await tester.scrollUntilVisible(
        find.text('This is your default card'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Set as default card'), findsNothing);
    },
  );

  testWidgets(
    'Save while offline queues nickname/credit-limit edits instead of failing outright',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      final owned = [
        const UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          nickname: 'Old',
          cardName: 'Test Card',
          isDefault: false,
        ),
      ];
      final (router, queue) = await _pumpOffline(
        tester,
        catalogue: [product],
        owned: owned,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Nickname'),
        'Renamed',
      );
      await tester.scrollUntilVisible(
        find.text('Save'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('Saved. It will sync in the background.'),
        findsOneWidget,
      );
      final patch = _lastCommands!.pendingOf({'card_fields_patch'}).single;
      expect(patch.target, 'uc1');
      expect(patch.payload['nickname'], 'Renamed');
      expect(queue.pending(), isEmpty);
      // An untouched points balance is never part of the card PATCH.
      expect(patch.payload.containsKey('pointsBalance'), isFalse);
    },
  );

  testWidgets(
    'Save while offline warns explicitly when the points balance also changed, since that field cannot be queued',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      final owned = [
        UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          cardName: 'Test Card',
          isDefault: false,
          totalPointsEarned: 100,
        ),
      ];
      final (_, queue) = await _pumpOffline(
        tester,
        catalogue: [product],
        owned: owned,
      );

      await tester.scrollUntilVisible(
        find.text('Current points balance'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Current points balance'),
        '500',
      );
      await tester.scrollUntilVisible(
        find.text('Save'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // WP-C6: the points balance is queued as a points adjustment (with a
      // client mutation id) instead of being refused offline.
      expect(
        find.textContaining('Points balance needs a live connection'),
        findsNothing,
      );
      expect(
        find.text('Saved. It will sync in the background.'),
        findsOneWidget,
      );
      final adjust = _lastCommands!.pendingOf({'points_adjust'}).single;
      expect(adjust.target, 'uc1');
      expect(adjust.payload['newBalance'], 500);
      expect(adjust.payload['clientMutationId'], isA<String>());
      expect(queue.pending(), isEmpty);
    },
  );

  testWidgets(
    'Save while offline sends last4 through the card PATCH too, since an old server drops it from /sync/push',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      final owned = [
        const UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          cardName: 'Test Card',
          isDefault: false,
        ),
      ];
      final (_, queue) = await _pumpOffline(
        tester,
        catalogue: [product],
        owned: owned,
      );
      await tester.enterText(find.widgetWithText(TextField, 'Last 4 digits'), '4321');
      await tester.scrollUntilVisible(
        find.text('Save'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(queue.pending(), isEmpty);
      final patch = _lastCommands!.pendingOf({'card_fields_patch'}).single;
      expect(patch.target, 'uc1');
      expect(patch.payload['cardId'], 'uc1');
      expect(patch.payload['last4'], '4321');
    },
  );

  testWidgets(
    'Remove card while offline is saved on the phone and queued',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      final owned = [
        const UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          nickname: 'Old',
          cardName: 'Test Card',
          isDefault: false,
        ),
      ];
      final (_, queue) = await _pumpOffline(
        tester,
        catalogue: [product],
        owned: owned,
      );

      await tester.scrollUntilVisible(
        find.text('Remove card'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Remove card'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove card'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Card removed on this device. It will sync when the server is available.',
        ),
        findsOneWidget,
      );
      // The card's own archive route carries it (a boolean the sync push may
      // refuse), so it is a command, not a sync-queue row.
      expect(queue.pending(), isEmpty);
      expect(_lastCommands!.pendingOf({'archive_card'}).single.target, 'uc1');
    },
  );

  testWidgets(
    'Set as default while offline is saved on the phone and queued like Card actions (WP-C6)',
    (tester) async {
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      final owned = [
        const UserCard(
          id: 'uc1',
          cardProductId: 'p1',
          cardName: 'Test Card',
          isDefault: false,
        ),
      ];
      final (_, queue) = await _pumpOffline(
        tester,
        catalogue: [product],
        owned: owned,
      );

      await tester.scrollUntilVisible(
        find.text('Set as default card'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Set as default card'));
      await tester.pumpAndSettle();

      expect(find.text('Set as your default card.'), findsOneWidget);
      // LocalFirstCards clears any other default in the same step, so two
      // cards can never end up flagged default.
      expect(queue.pending(), isEmpty);
      expect(_lastCommands!.pendingOf({'set_default'}).single.target, 'uc1');
      final cards = _lastStore!.entities('legacy', 'cards');
      expect(cards.single['is_default'], isTrue);
    },
  );
}
