import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local_first/card_overrides_overlay.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';

class _Repo implements UserCardsRepository {
  _Repo(this.answer);
  final Future<({String id, bool existing})> Function(String clientId) answer;
  final calls = <String>[];
  final updates = <String>[];
  final defaults = <String>[];

  @override
  Future<({String id, bool existing})> addCardWithClientId(
    String clientId,
    String cardProductId, {
    String? nickname,
    String? last4,
    bool mergeExisting = true,
  }) {
    calls.add(clientId);
    return answer(clientId);
  }

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
  }) async => updates.add('$userCardId:$creditLimitInr');

  @override
  Future<void> setDefaultCard(String userCardId) async =>
      defaults.add(userCardId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const ns = 'a';
  late AppDatabase db;
  late FinancialStore store;
  late CommandOutbox commands;
  late SyncQueue queue;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    commands = CommandOutbox(db, namespace: ns);
    queue = SyncQueue(db, namespace: ns);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  CardCommandContext ctx(_Repo repo) => CardCommandContext(
    userCards: repo,
    overrides: null,
    commands: commands,
    db: db.db,
    namespace: ns,
  );

  test('remapIdInJson swaps whole string values only, never keys', () {
    final out = remapIdInJson(
      {
        'userCardId': 'old',
        'old': 'keep-key',
        'nested': [
          {'x': 'old'},
          'older',
          3,
        ],
      },
      'old',
      'new',
    );
    expect(out, {
      'userCardId': 'new',
      'old': 'keep-key',
      'nested': [
        {'x': 'new'},
        'older',
        3,
      ],
    });
    expect(remapIdInJsonText('not json old', 'old', 'new'), 'not json old');
  });

  test(
    'remapLocalId rewrites the card, queued edits, commands, outbox rows and cache',
    () {
      insertProvisionalCard(
        store,
        ns,
        provisionalCard('loc', null, cardProductId: 'p1'),
      );
      queue.enqueueUpdate(
        entity: 'user_cards',
        entityId: 'loc',
        fields: {'sort_order': 2},
      );
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 't1',
        fields: {'user_card_id': 'loc'},
      );
      commands.enqueue(
        kind: CardCommand.createOverride,
        target: 'ov',
        payload: {'id': 'ov', 'userCardId': 'loc'},
      );
      commands.enqueue(
        kind: 'points_adjust',
        target: 'loc',
        payload: {'userCardId': 'loc'},
      );
      db.db.execute(
        "INSERT INTO transaction_outbox_entries(user_card_id, amount_paise, created_at) VALUES ('loc', 100, 1)",
      );
      db.db.execute(
        "INSERT INTO cached_responses(key, raw_json, fetched_at) VALUES ('a:card_overrides', ?, 1)",
        [
          jsonEncode({
            'overrides': [
              {'id': 'ov', 'user_card_id': 'loc'},
            ],
          }),
        ],
      );

      remapLocalId(db.db, ns, 'loc', 'srv');

      expect(store.entities(ns, 'cards').map((c) => c['id']), ['srv']);
      expect(
        db.db
            .select("SELECT pending FROM financial_entities WHERE id='srv'")
            .single['pending'],
        0,
      );
      final edits = queue.pending();
      expect(edits.map((e) => e.entityId), containsAll(['srv', 't1']));
      expect(
        edits.firstWhere((e) => e.entityId == 't1').payload['user_card_id'],
        'srv',
      );
      expect(
        commands
            .pendingOf({CardCommand.createOverride})
            .single
            .payload['userCardId'],
        'srv',
      );
      expect(commands.pendingOf({'points_adjust'}).single.target, 'srv');
      expect(
        db.db
            .select('SELECT user_card_id FROM transaction_outbox_entries')
            .single['user_card_id'],
        'srv',
      );
      expect(
        db.db
            .select(
              "SELECT raw_json FROM cached_responses WHERE key='a:card_overrides'",
            )
            .single['raw_json'],
        contains('"user_card_id":"srv"'),
      );
    },
  );

  test(
    'remapLocalId drops the provisional row when the server card is already stored',
    () {
      insertProvisionalCard(
        store,
        ns,
        provisionalCard('loc', null, cardProductId: 'p1'),
      );
      store.replaceCards(ns, [
        const UserCard(
          id: 'srv',
          cardProductId: 'p1',
          cardName: 'C',
          isDefault: false,
        ),
      ]);
      expect(store.entities(ns, 'cards'), hasLength(2));
      remapLocalId(db.db, ns, 'loc', 'srv');
      expect(store.entities(ns, 'cards').map((c) => c['id']), ['srv']);
    },
  );

  test('H3-8: remapLocalId moves an SMS instrument link to the server card', () {
    db.db.execute(
      'CREATE TABLE v2_instruments (namespace TEXT NOT NULL, instrument_id TEXT NOT NULL, '
      'kind TEXT NOT NULL, issuer_slug TEXT NOT NULL, mask_digits TEXT, status TEXT NOT NULL, '
      'payload TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (namespace, instrument_id))',
    );
    db.db.execute(
      "INSERT INTO v2_instruments(namespace,instrument_id,kind,issuer_slug,status,payload) "
      "VALUES (?, 'i1', 'creditCard', 'x', 'confirmed', ?)",
      [ns, jsonEncode({'userCardId': 'loc'})],
    );
    remapLocalId(db.db, ns, 'loc', 'srv');
    final payload = db.db.select('SELECT payload FROM v2_instruments').single['payload'] as String;
    expect(jsonDecode(payload)['userCardId'], 'srv');
  });

  test('add_card with the same id on the server settles the provisional card', () async {
    insertProvisionalCard(
      store,
      ns,
      provisionalCard('loc', null, cardProductId: 'p1'),
    );
    final repo = _Repo((id) async => (id: id, existing: false));
    await cardCommandHandlers(ctx(repo))[CardCommand.addCard]!({
      'id': 'loc',
      'cardProductId': 'p1',
    });
    final row = db.db
        .select("SELECT id, pending FROM financial_entities WHERE entity='cards'")
        .single;
    expect([row['id'], row['pending']], ['loc', 0]);
  });

  test(
    'add_card on an old server remaps to the server id and queues the patch separately',
    () async {
      insertProvisionalCard(
        store,
        ns,
        provisionalCard('loc', null, cardProductId: 'p1'),
      );
      final repo = _Repo((_) async => (id: 'srv', existing: false));
      await cardCommandHandlers(ctx(repo))[CardCommand.addCard]!({
        'id': 'loc',
        'cardProductId': 'p1',
        'patch': {'creditLimitInr': 50000},
      });
      expect(store.entities(ns, 'cards').single['id'], 'srv');
      final patch = commands.pendingOf({CardCommand.patchCardFields}).single;
      expect(patch.target, 'srv');
      expect(patch.payload['cardId'], 'srv');
      await cardCommandHandlers(ctx(repo))[CardCommand.patchCardFields]!(
        patch.payload,
      );
      expect(repo.updates, ['srv:50000.0']);
    },
  );

  test('add_card for a card the person already had merges into that card', () async {
    insertProvisionalCard(
      store,
      ns,
      provisionalCard('loc', null, cardProductId: 'p1'),
    );
    store.replaceCards(ns, [
      const UserCard(
        id: 'exists',
        cardProductId: 'p1',
        cardName: 'C',
        isDefault: false,
      ),
    ]);
    final repo = _Repo((_) async => (id: 'exists', existing: true));
    await cardCommandHandlers(ctx(repo))[CardCommand.addCard]!({
      'id': 'loc',
      'cardProductId': 'p1',
    });
    expect(store.entities(ns, 'cards').map((c) => c['id']), ['exists']);
  });

  test('a permanent refusal parks the add and the card shows as not saved', () async {
    insertProvisionalCard(
      store,
      ns,
      provisionalCard('loc', null, cardProductId: 'p1'),
    );
    commands.enqueue(
      kind: CardCommand.addCard,
      target: 'loc',
      payload: {'id': 'loc', 'cardProductId': 'p1'},
    );
    expect(cardSaveStatesFor(commands).saving, {'loc'});
    final repo = _Repo(
      (_) => throw ApiException('POST /user-cards failed: 400 {"error":"bad"}'),
    );
    await commands.flush(cardCommandHandlers(ctx(repo)));
    final states = cardSaveStatesFor(commands);
    expect(states.saving, isEmpty);
    expect(states.notSaved, {'loc'});
    // The provisional card is still shown, and survives a wallet refresh.
    store.replaceCards(ns, []);
    expect(store.entities(ns, 'cards').single['id'], 'loc');
  });

  test('flushing add_card first leaves other kinds queued', () async {
    commands.enqueue(
      kind: CardCommand.addCard,
      target: 'loc',
      payload: {'id': 'loc', 'cardProductId': 'p1'},
    );
    commands.enqueue(kind: 'ignore_transaction', target: 't', payload: {});
    final repo = _Repo((id) async => (id: id, existing: false));
    final sent = await commands.flush(
      cardCommandHandlers(ctx(repo)),
      onlyKinds: CardCommand.addFirst,
    );
    expect(sent, 1);
    expect(commands.pendingCount, 1);
  });

  group('overlayCardOverrides', () {
    final base = [
      CardOverride(
        id: 'o1',
        userCardId: 'c1',
        scope: OverrideScope.category,
        categoryId: 'dining',
        isEnabled: true,
        createdAt: DateTime(2026),
        cardName: 'Card One',
      ),
    ];
    test('shows a rule created offline, hides a deleted one, applies edits', () {
      final out = overlayCardOverrides(
        base,
        [
          const PendingCommand(
            kind: 'create_override',
            target: 'o2',
            payload: {
              'id': 'o2',
              'userCardId': 'c1',
              'scope': 'merchantName',
              'merchantName': 'Cafe',
              'cardName': 'Card One',
            },
          ),
        ],
        const [
          OverrideEdit('o1', {'is_enabled': false}),
        ],
      );
      expect(out.map((o) => o.id), ['o1', 'o2']);
      expect(out.first.isEnabled, isFalse);
      expect(out.last.merchantName, 'Cafe');
      final gone = overlayCardOverrides(
        base,
        [
          const PendingCommand(
            kind: 'delete_override',
            target: 'o1',
            payload: {'id': 'o1'},
          ),
        ],
        const [],
      );
      expect(gone, isEmpty);
    });
    test('moving a rule to another card shows that card name', () {
      final out = overlayCardOverrides(
        base,
        const [],
        const [
          OverrideEdit('o1', {'user_card_id': 'c2', 'reason_note': ''}),
        ],
        cardLabels: {'c2': (name: 'Card Two', nickname: 'Two')},
      );
      expect(out.single.userCardId, 'c2');
      expect(out.single.cardName, 'Card Two');
      expect(out.single.cardNickname, 'Two');
      expect(out.single.reasonNote, isNull);
    });
  });
}
