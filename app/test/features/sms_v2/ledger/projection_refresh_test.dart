import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/instruments/unlinked_card_healer.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_refresh.dart';
import 'package:pandapay/features/sms_v2/pipeline/capture_executor.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/personal/personal_rule_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// A saved Activity row is a copy made when its message was read. When what it
// was built from changes later (a card linked to a wallet card, renamed, a new
// app version that projects differently), the refresh rebuilds it, in slices,
// without reading the message again and without moving its category.
void main() {
  const namespace = 'user:refresh';
  const walletCardId = '11111111-1111-4111-8111-111111111111';
  const categories = {
    'other': 'cat-other',
    'dining': 'cat-dining',
    'groceries': 'cat-groceries',
    'online': 'cat-online',
    'travel': 'cat-travel',
    'bills': 'cat-bills',
    'fuel': 'cat-fuel',
    'entertainment': 'cat-entertainment',
    'health': 'cat-health',
  };
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late Instrument card;

  late Database db;
  List<Map<String, Object?>> rows() =>
      financial.entities(namespace, 'transactions');
  Map<String, Object?> row() => rows().single;
  ProjectionRefresh refresh({Map<String, String> ids = categories}) =>
      ProjectionRefresh(
        financial: financial,
        namespace: namespace,
        bundle: bundle,
        categoryIdBySlug: ids,
      );
  int outboxLedger() => db
      .select(
        "SELECT count(*) AS n FROM v2_outbox WHERE namespace=? AND kind='ledger'",
        [namespace],
      )
      .single['n'] as int;
  void clearOutbox() =>
      db.execute('DELETE FROM v2_outbox WHERE namespace=?', [namespace]);

  void editRow(Map<String, Object?> Function(Map<String, Object?>) change) {
    final r = row();
    db.execute(
      "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
      [jsonEncode(change(r)), namespace, r['id']],
    );
  }

  /// The state an older build left behind: the fact names the card, but the
  /// saved row says "Payment method not matched" and the ledger entry points at
  /// a card record that no longer exists.
  void makeStale() {
    editRow(
      (r) => {
        ...r,
        'instrument': 'other',
        'user_card_id': null,
        'card_last4': null,
        'card_name': null,
      },
    );
    for (final entry in db.select(
      'SELECT entry_id,payload FROM v2_ledger WHERE namespace=?',
      [namespace],
    )) {
      final j = jsonDecode(entry['payload'] as String) as Map<String, Object?>;
      if ((j['from'] as Map?)?['instrumentId'] != null) {
        j['from'] = {'instrumentId': '99999999-9999-4999-8999-999999999999'};
      }
      db.execute(
        'UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?',
        [jsonEncode(j), namespace, entry['entry_id']],
      );
    }
  }

  String? ledgerFrom() {
    final j = jsonDecode(
      db.select('SELECT payload FROM v2_ledger WHERE namespace=?', [
        namespace,
      ]).single['payload'] as String,
    ) as Map;
    return (j['from'] as Map?)?['instrumentId'] as String?;
  }

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    db = database.db;
    financial = FinancialStore(database);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    final message = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: bundle.rules.first.examples.first.body,
      sourceKey: '1' * 64,
      observedAt: DateTime.utc(2026, 11, 1, 7),
    );
    SmsIntakeRepository(database);
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
      categoryIdBySlug: categories,
    ).process(message);
    card = InstrumentStore(db, namespace: namespace).list().single;
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  test('right after capture there is nothing to rebuild', () {
    clearOutbox();
    final before = jsonEncode(row());
    expect(refresh().runAll(), 0);
    expect(jsonEncode(row()), before);
    expect(outboxLedger(), 0);
    expect(refresh().pending, isFalse);
  });

  test('a stale "not matched" row whose fact names a linked card is rebuilt', () {
    refresh().runAll();
    // The card is linked to a wallet card after the row was saved.
    InstrumentStore(db, namespace: namespace).upsert(
      card.copyWith(
        status: InstrumentStatus.confirmed,
        userCardId: walletCardId,
      ),
    );
    makeStale();
    editRow(
      (r) => {
        ...r,
        'note': 'dinner with A',
        'tags': [
          {'id': 'tag-1', 'name': 'Trip'},
        ],
      },
    );
    final categoryBefore = row()['category_id'];
    clearOutbox();

    // The existing heal cannot reach it: the fact already has a card record.
    expect(
      UnlinkedCardHealer(financial, namespace: namespace)
          .healAll(now: DateTime.utc(2026, 11, 15)),
      0,
    );
    expect(row()['instrument'], 'other');

    expect(refresh().pending, isTrue);
    expect(refresh().runAll(), 1);
    final r = row();
    expect(r['instrument'], 'credit_card');
    expect(r['user_card_id'], walletCardId);
    expect(r['card_last4'], card.maskDigits);
    expect(r['card_name'], card.displayName);
    // The person's own edits and the category stay.
    expect(r['note'], 'dinner with A');
    expect((r['tags'] as List).single['name'], 'Trip');
    expect(r['category_id'], categoryBefore);
    // The ledger points at the real card again, and that change is uploaded.
    expect(ledgerFrom(), card.instrumentId);
    expect(outboxLedger(), 1);

    // Done: a second run changes nothing and queues nothing.
    clearOutbox();
    expect(refresh().pending, isFalse);
    expect(refresh().runAll(), 0);
    expect(outboxLedger(), 0);
  });

  test('renaming a card starts a new pass that renames its rows', () {
    InstrumentStore(db, namespace: namespace).upsert(
      card.copyWith(userCardId: walletCardId),
    );
    refresh().runAll();
    expect(refresh().pending, isFalse);
    InstrumentStore(db, namespace: namespace).upsert(
      card.copyWith(userCardId: walletCardId, displayName: 'My dining card'),
    );
    expect(refresh().pending, isTrue);
    expect(refresh().runAll(), 1);
    expect(row()['card_name'], 'My dining card');
  });

  test('a balance update on the card does not start a pass', () {
    refresh().runAll();
    InstrumentStore(db, namespace: namespace).upsert(
      card.copyWith(evidenceCount: card.evidenceCount + 5),
    );
    expect(refresh().pending, isFalse);
  });

  test('a category stays as stored even when the rules would pick another', () {
    refresh().runAll();
    // The stored decision is changed directly, as a re-sort or a user choice
    // would have done.
    for (final entry in db.select(
      'SELECT entry_id,payload FROM v2_ledger WHERE namespace=?',
      [namespace],
    )) {
      final j = jsonDecode(entry['payload'] as String) as Map<String, Object?>;
      j['_categoryDecision'] = {
        'slug': 'travel',
        'source': 'default',
        'ruleId': null,
        'confidence': 1,
      };
      db.execute(
        'UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?',
        [jsonEncode(j), namespace, entry['entry_id']],
      );
    }
    makeStale();
    SyncStateStore(db, namespace: namespace).put(ProjectionRefresh.doneKey, '');
    refresh().runAll();
    expect(row()['category_id'], 'cat-travel');
  });

  test('without category ids nothing is written', () {
    makeStale();
    SyncStateStore(db, namespace: namespace).put(ProjectionRefresh.doneKey, '');
    expect(refresh(ids: const {}).runAll(), 0);
    expect(row()['instrument'], 'other');
  });

  test('a pass runs in slices and continues after a restart', () {
    // Two more events, each from its own message.
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
      categoryIdBySlug: categories,
    );
    for (final (i, day) in [(2, 2), (3, 3)]) {
      pipeline.process(
        SmsMessage(
          sender: 'VM-HDFCBK-S',
          body: bundle.rules.first.examples.first.body.replaceFirst(
            RegExp(r'\d+(\.\d+)?'),
            '${100 + i}',
          ),
          sourceKey: '$i' * 64,
          observedAt: DateTime.utc(2026, 11, day, 7),
        ),
      );
    }
    final events = db
        .select('SELECT count(*) AS n FROM v2_events WHERE namespace=?', [
          namespace,
        ])
        .single['n'] as int;
    expect(events, greaterThan(1));
    final state = SyncStateStore(db, namespace: namespace);
    state.put(ProjectionRefresh.doneKey, 'old');
    final first = refresh().step(limit: 1);
    expect(first.events, 1);
    expect(first.more, isTrue);
    final cursor = state.get(ProjectionRefresh.cursorKey);
    expect(cursor, isNotEmpty);
    // A new instance (the app was closed) carries on from the cursor.
    var steps = 1;
    while (refresh().step(limit: 1).more) {
      steps++;
    }
    expect(steps + 1, greaterThanOrEqualTo(events));
    expect(refresh().pending, isFalse);
    expect(state.get(ProjectionRefresh.cursorKey), '');
  });

  group('a message is always on the card it printed', () {
    const otherWalletCard = '22222222-2222-4222-8222-222222222222';
    const otherCardId = '33333333-3333-4333-8333-333333333333';

    String? factCard() => db
        .select(
          'SELECT DISTINCT instrument_id FROM v2_facts WHERE namespace=? AND fact_id IN (SELECT event_id FROM v2_events WHERE namespace=?)',
          [namespace, namespace],
        )
        .single['instrument_id'] as String?;

    /// The message names [card] (linked to a wallet card). Something stored a
    /// link to another card ([issuer], [mask]) for it, as an edit applied to
    /// similar messages did in Nov 2026.
    void linkToOtherCard({required String issuer, required String mask}) {
      final store = InstrumentStore(db, namespace: namespace);
      store.upsert(card.copyWith(status: InstrumentStatus.confirmed, userCardId: walletCardId));
      store.upsert(
        Instrument.fromJson({
          ...card.toJson(),
          'instrumentId': otherCardId,
          'issuerSlug': issuer,
          'maskDigits': mask,
          'displayName': 'Other card',
          'status': 'confirmed',
          'userCardId': otherWalletCard,
        }),
      );
      refresh().runAll();
      db.execute(
        'UPDATE v2_facts SET instrument_id=? WHERE namespace=? AND fact_id IN (SELECT event_id FROM v2_events WHERE namespace=?)',
        [otherCardId, namespace, namespace],
      );
      // What an older build saved from that link: the ledger and the row
      // name the other card.
      for (final entry in db.select('SELECT entry_id,payload FROM v2_ledger WHERE namespace=?', [namespace])) {
        final j = jsonDecode(entry['payload'] as String) as Map<String, Object?>;
        if ((j['from'] as Map?)?['instrumentId'] != null) j['from'] = {'instrumentId': otherCardId};
        db.execute('UPDATE v2_ledger SET payload=? WHERE namespace=? AND entry_id=?', [jsonEncode(j), namespace, entry['entry_id']]);
      }
      editRow((r) => {...r, 'user_card_id': otherWalletCard, 'card_last4': mask, 'card_name': 'Other card'});
      expect(ledgerFrom(), otherCardId);
      clearOutbox();
      // A new build (projection code version) starts the pass.
      SyncStateStore(db, namespace: namespace).put(ProjectionRefresh.doneKey, 'old');
    }

    test('a link to another bank\'s card is pointed back, and the ledger is uploaded again', () {
      linkToOtherCard(issuer: 'zz_other_bank', mask: '1260');
      expect(refresh().runAll(), 1);
      expect(factCard(), card.instrumentId);
      expect(ledgerFrom(), card.instrumentId);
      expect(row()['user_card_id'], walletCardId);
      expect(row()['card_last4'], card.maskDigits);
      expect(outboxLedger(), 1);
      clearOutbox();
      expect(refresh().runAll(), 0);
      expect(outboxLedger(), 0);
    });

    test('a link to another number of the same bank is pointed back too', () {
      linkToOtherCard(issuer: card.issuerSlug, mask: '0000');
      refresh().runAll();
      expect(factCard(), card.instrumentId);
      expect(ledgerFrom(), card.instrumentId);
    });

    test('a link to the same number printed longer is left alone', () {
      // Not the same instrument, but nothing the message printed rules it out.
      linkToOtherCard(issuer: card.issuerSlug, mask: '99${card.maskDigits}');
      refresh().runAll();
      expect(factCard(), otherCardId);
      expect(ledgerFrom(), otherCardId);
    });
  });

  test('a slice that keeps failing is passed over after three tries', () {
    // An event that cannot be read stands for any slice that keeps throwing.
    db.execute(
      "UPDATE v2_events SET payload='{not json' WHERE namespace=?",
      [namespace],
    );
    final state = SyncStateStore(db, namespace: namespace);
    state.put(ProjectionRefresh.doneKey, 'old');
    void slice() => runCaptureChunk(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      overlayRevision: 'r',
      engine: RuleEngine(),
      personalRules: PersonalRuleStore(state),
      appVersion: '2',
      categoryIdBySlug: categories,
      groups: const [],
      ownerNames: const [],
      refreshProjection: true,
    );
    expect(slice, throwsA(anything));
    expect(refresh().pending, isTrue);
    expect(slice, throwsA(anything));
    expect(refresh().pending, isTrue);
    // Third failure at the same place: the slice is passed over.
    expect(slice, throwsA(anything));
    expect(refresh().pending, isFalse);
    expect(state.get(ProjectionRefresh.failuresKey), '');
  });
}
