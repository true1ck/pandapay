import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';
import 'package:pandapay/features/cards/card_state_local_first.dart';
import 'package:pandapay/features/overrides/override_local_first.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _Repo implements UserCardsRepository {
  final adds = <String>[];
  String? answerWith;

  @override
  Future<({String id, bool existing})> addCardWithClientId(
    String clientId,
    String cardProductId, {
    String? nickname,
    String? last4,
    bool mergeExisting = true,
  }) async {
    adds.add(clientId);
    return (id: answerWith ?? clientId, existing: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OverridesRepo extends CardOverridesRepository {
  _OverridesRepo() : super(apiBaseUrl: 'http://localhost', accessToken: 't');
  int creates = 0;

  @override
  Future<List<CardOverride>> fetchOverrides() async => const [];

  @override
  Future<CardOverride> createOverride({
    required String userCardId,
    required OverrideScope scope,
    String? vpa,
    String? merchantName,
    String? categoryId,
    String? reasonNote,
    String? id,
  }) async {
    creates++;
    return CardOverride(
      id: id ?? 'server-id',
      userCardId: userCardId,
      scope: scope,
      vpa: vpa,
      isEnabled: true,
      createdAt: DateTime(2026),
      cardName: 'C',
    );
  }
}

void main() {
  late WidgetRef ref;
  late ResponseCache cache;
  late _Repo repo;
  late _OverridesRepo overrides;
  const ns = 'user:t';
  final product = CardProduct(
    id: 'p1',
    name: 'Test Card',
    network: CardNetwork.rupay,
    cardType: 'credit',
  );

  Future<void> pump(WidgetTester tester, {required bool offline}) async {
    KnownConnectivity.online = !offline;
    addTearDown(KnownConnectivity.reset);
    cache = ResponseCache(openInMemoryForTesting());
    repo = _Repo();
    overrides = _OverridesRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          responseCacheProvider.overrideWith((r) async => cache),
          cacheNamespaceProvider.overrideWithValue(ns),
          userCardsRepositoryProvider.overrideWithValue(repo),
          cardOverridesRepositoryProvider.overrideWithValue(overrides),
          isOnlineProvider.overrideWith((r) => Stream.value(!offline)),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('offline add shows a pending card at once and queues add_card', (
    tester,
  ) async {
    await pump(tester, offline: true);
    final out = await tester.runAsync(
      () => addCardLocalFirst(
        ref,
        cardProductId: 'p1',
        product: product,
        last4: '1234',
        creditLimitInr: 50000,
      ),
    );
    expect(out!.queued, isTrue);
    expect(repo.adds, isEmpty);
    final cards = cache.financialStore.entities(ns, 'cards');
    expect(cards.single['id'], out.id);
    expect(cards.single['card_name'], 'Test Card');
    expect(cards.single['last4'], '1234');
    final commands = await tester.runAsync(
      () => ref.read(commandOutboxProvider.future),
    );
    final add = commands!.pendingOf({CardCommand.addCard}).single;
    expect(add.target, out.id);
    expect(add.payload['patch'], {'creditLimitInr': 50000.0});
    // The same tap twice does not queue a second copy.
    final again = await tester.runAsync(
      () => addCardLocalFirst(
        ref,
        cardProductId: 'p1',
        product: product,
        last4: '1234',
      ),
    );
    expect(again!.id, out.id);
    expect(commands.pendingOf({CardCommand.addCard}), hasLength(1));
    // A wallet refresh that does not list the card keeps it (L-03).
    cache.financialStore.replaceCards(ns, const []);
    expect(cache.financialStore.entities(ns, 'cards'), hasLength(1));
  });

  testWidgets('delivering the queued add remaps to the server id', (
    tester,
  ) async {
    await pump(tester, offline: true);
    final out = await tester.runAsync(
      () => addCardLocalFirst(ref, cardProductId: 'p1', product: product),
    );
    repo.answerWith = 'server-card';
    final ctx = await tester.runAsync(() => cardCommandContext(ref));
    final commands = ctx!.commands;
    final sent = await tester.runAsync(
      () => commands.flush(cardCommandHandlers(ctx)),
    );
    expect(sent, 1);
    expect(repo.adds, [out!.id]);
    expect(cache.financialStore.entities(ns, 'cards').single['id'], 'server-card');
    expect(commands.pendingCount, 0);
  });

  testWidgets('online add is one server call and nothing is queued', (
    tester,
  ) async {
    await pump(tester, offline: false);
    final out = await tester.runAsync(
      () => addCardLocalFirst(ref, cardProductId: 'p1', product: product),
    );
    expect(out!.queued, isFalse);
    expect(repo.adds, [out.id]);
    final commands = await tester.runAsync(
      () => ref.read(commandOutboxProvider.future),
    );
    expect(commands!.pendingCount, 0);
    expect(cache.financialStore.entities(ns, 'cards'), isEmpty);
  });

  testWidgets('offline: a created override appears, a deleted one disappears', (
    tester,
  ) async {
    await pump(tester, offline: true);
    const card = UserCard(
      id: 'c1',
      cardProductId: 'p1',
      cardName: 'Card One',
      isDefault: false,
    );
    final saved = await tester.runAsync(
      () => createOverrideLocalFirst(
        ref,
        card: card,
        scope: OverrideScope.merchantName,
        merchantName: 'Cafe',
      ),
    );
    expect(saved, isFalse);
    expect(overrides.creates, 0);
    var list = await tester.runAsync(() => ref.read(cardOverridesProvider.future));
    expect(list!.single.merchantName, 'Cafe');
    final id = list.single.id;

    // Deleting a rule that is still only queued just cancels it.
    final deleted = await tester.runAsync(
      () => deleteOverrideLocalFirst(ref, id),
    );
    expect(deleted, isFalse);
    list = await tester.runAsync(() => ref.read(cardOverridesProvider.future));
    expect(list, isEmpty);
    final commands = await tester.runAsync(
      () => ref.read(commandOutboxProvider.future),
    );
    expect(commands!.pendingCount, 0);
  });

  testWidgets('archiving a card that never reached the server just forgets it', (
    tester,
  ) async {
    await pump(tester, offline: true);
    final out = await tester.runAsync(
      () => addCardLocalFirst(ref, cardProductId: 'p1', product: product),
    );
    await tester.runAsync(
      () => setCardArchived(ref, out!.id, archived: true),
    );
    expect(cache.financialStore.entities(ns, 'cards'), isEmpty);
    final commands = await tester.runAsync(
      () => ref.read(commandOutboxProvider.future),
    );
    expect(commands!.pendingCount, 0);
  });

  testWidgets('offline: a queued toggle visibly flips the saved rule', (
    tester,
  ) async {
    await pump(tester, offline: true);
    final rule = CardOverride(
      id: 'o1',
      userCardId: 'c1',
      scope: OverrideScope.vpa,
      vpa: 'shop@upi',
      isEnabled: true,
      createdAt: DateTime(2026),
      cardName: 'Card One',
    );
    await tester.runAsync(
      () => cache.put(
        '$ns:card_overrides',
        jsonEncode({
          'overrides': [rule.toJson()],
        }),
      ),
    );
    var list = await tester.runAsync(() => ref.read(cardOverridesProvider.future));
    expect(list!.single.isEnabled, isTrue);
    final saved = await tester.runAsync(
      () => updateOverrideLocalFirst(ref, rule, isEnabled: false),
    );
    expect(saved, isFalse);
    expect(overrides.creates, 0);
    list = await tester.runAsync(() => ref.read(cardOverridesProvider.future));
    expect(list!.single.isEnabled, isFalse);
  });
}
