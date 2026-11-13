// The saved subscription rows: they are what every screen reads, so they must
// round-trip exactly, follow the ledger as messages arrive, and give the same
// series as deriving straight from the ledger.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/ledger/subscription_projection.dart';
import 'package:pandapay/features/sms_v2/ledger/subscription_rebuild.dart';
import 'package:pandapay/features/sms_v2/ledger/subscription_state.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/subscription_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:store';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  var n = 0;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    final json = (jsonDecode(jsonEncode(testRuleBundle().toJson())) as Map)
        .cast<String, Object?>();
    json['solverPack'] =
        (jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync())
                as Map)
            .cast<String, Object?>();
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: RuleBundle.fromJson(json),
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  SubscriptionStore store([String ns = _ns]) =>
      SubscriptionStore(db.db, namespace: ns);

  void send(String sender, String body, String day) {
    n++;
    pipeline.process(
      SmsMessage(
        sender: sender,
        body: body,
        sourceKey: n.toRadixString(16).padLeft(64, '0'),
        observedAt: DateTime.parse('${day}T06:00:00Z'),
      ),
    );
  }

  const mandate =
      'UPI Mandate created successfully for NETFLIX for Rs 649.00 monthly on A/c XX1234. UMN abc@axis. To pause or revoke, use your UPI app. -Axis Bank';
  String debit(String d) =>
      'INR 649.00 debited from your A/c XX1234 on $d towards NETFLIX INDIA for UPI Mandate. UMRN abc@axis. -Axis Bank';

  // Capture only marks the saved rows dirty; the next reader derives them.
  void derive() => SubscriptionProjection.rebuildIfNeeded(db.db, _ns);

  List<Map<String, Object?>> asJson(List<RecurringSeries> series) => [
    for (final s in series) s.toJson(),
  ];

  test('the migration creates both tables and records version 4', () {
    final fresh = sqlite3.openInMemory();
    addTearDown(fresh.dispose);
    SmsV2Schema.ensure(fresh);
    final tables = fresh
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'])
        .toSet();
    expect(tables, containsAll(['v2_subscriptions', 'v2_subscription_history']));
    expect(SmsV2Schema.installedVersion(fresh), 4);
  });

  test('a database already at version 3 gains the tables and keeps its data', () {
    final old = sqlite3.openInMemory();
    addTearDown(old.dispose);
    SmsV2Schema.ensure(old);
    old.execute('DROP TABLE v2_subscriptions');
    old.execute('DROP TABLE v2_subscription_history');
    old.execute("UPDATE sms_v2_schema_version SET version=3 WHERE module='sms_v2'");
    old.execute(
      "INSERT INTO v2_events (namespace, event_id, type, status, payload, dirty) VALUES ('a','e1','purchase','complete','{}',0)",
    );
    SmsV2Schema.ensure(old);
    expect(SmsV2Schema.installedVersion(old), 4);
    expect(old.select('SELECT * FROM v2_events'), hasLength(1));
    expect(old.select('SELECT * FROM v2_subscriptions'), isEmpty);
  });

  test('rows round-trip exactly and are kept per account', () {
    final state = SubscriptionState(
      kind: SubscriptionStateKind.mandate,
      key: 'NETFLIX',
      name: 'NETFLIX',
      cadence: 30,
      chargeCount: 3,
      firstChargeAt: DateTime.utc(2026, 8, 3),
      lastChargeAt: DateTime.utc(2026, 10, 3),
      lastAmountMinor: 64900,
      ceilingMinor: 100000,
      latestPhase: 'created',
      latestPhaseAt: DateTime.utc(2026, 8, 1),
      firstMandateAt: DateTime.utc(2026, 8, 1),
      mandateReference: 'abc@axis',
      lastFailureAt: DateTime.utc(2026, 9, 1),
      dueAts: [DateTime.utc(2026, 11, 3)],
      sourceKey: 'k',
    );
    final history = {
      state.seriesId: [
        SubscriptionHistoryEntry(
          kind: SubscriptionHistoryKind.charge,
          at: DateTime.utc(2026, 10, 3),
          amountMinor: 64900,
        ),
        SubscriptionHistoryEntry(
          kind: SubscriptionHistoryKind.setup,
          at: DateTime.utc(2026, 8, 1),
          amountMinor: 100000,
          sourceKey: 'k',
        ),
      ],
    };
    store().replaceAll([state], history);
    expect(store().states().single.toJson(), state.toJson());
    final read = store().historyFor(state.seriesId);
    expect([for (final e in read) e.kind], [
      SubscriptionHistoryKind.charge,
      SubscriptionHistoryKind.setup,
    ]);
    expect(read.last.amountMinor, 100000);
    expect(read.last.sourceKey, 'k');
    expect(store().allHistory().keys, [state.seriesId]);
    expect(store('user:other').states(), isEmpty);
    expect(store('user:other').isCurrent, isFalse);
  });

  test('replaceAll swaps the whole account and clears the dirty flag', () {
    final a = const SubscriptionState(
      kind: SubscriptionStateKind.mandate,
      key: 'A',
      name: 'A',
    );
    final b = const SubscriptionState(
      kind: SubscriptionStateKind.mandate,
      key: 'B',
      name: 'B',
    );
    store().replaceAll([a], const {});
    store().markDirty();
    expect(store().isCurrent, isFalse);
    store().replaceAll([b], const {});
    expect([for (final s in store().states()) s.key], ['B']);
    expect(store().isCurrent, isTrue);
  });

  group('following the ledger', () {
    test('messages that make a subscription save it; the saved rows give the same series as the ledger', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      send('AX-AXISBK-S', debit('03-09-26'), '2026-09-03');
      send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
      expect(store().isDirty, isTrue, reason: 'capture does not derive');
      derive();
      expect(store().isCurrent, isTrue);
      final now = DateTime.utc(2026, 11, 9);
      final saved = seriesFromSubscriptionStates(store().states(), now);
      final derived = subscriptionsFromLedger(
        FactStore(db.db, namespace: _ns).all(),
        EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
        now: now,
      );
      expect(saved, hasLength(1));
      expect(asJson(saved), asJson(derived));
      expect(saved.single.occurrenceCount, 3);
    });

    test('the same saved row is active today and past months later, with no new message', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
      derive();
      final rows = store().states();
      expect(
        seriesFromSubscriptionStates(rows, DateTime.utc(2026, 10, 20)).single.lifecycleStatus,
        'active',
      );
      expect(
        seriesFromSubscriptionStates(rows, DateTime.utc(2027, 3, 1)).single.lifecycleStatus,
        'lapsed',
      );
    });

    test('a later cancellation updates the saved row and its history', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      send(
        'AX-AXISBK-S',
        'AutoPay mandate for NETFLIX has been revoked successfully. -Axis Bank',
        '2026-09-02',
      );
      derive();
      final series = seriesFromSubscriptionStates(
        store().states(),
        DateTime.utc(2026, 9, 10),
      ).single;
      expect(series.lifecycleStatus, 'cancelled');
      expect(
        store().historyFor(series.id).first.kind,
        SubscriptionHistoryKind.cancelled,
      );
    });

    test('a history import marks the rows dirty and derives nothing per chunk', () {
      final messages = [
        SmsMessage(
          sender: 'AX-AXISBK-S',
          body: mandate,
          sourceKey: 'a'.padLeft(64, '0'),
          observedAt: DateTime.utc(2026, 8, 1, 6),
        ),
        SmsMessage(
          sender: 'AX-AXISBK-S',
          body: debit('03-08-26'),
          sourceKey: 'b'.padLeft(64, '0'),
          observedAt: DateTime.utc(2026, 8, 3, 6),
        ),
      ];
      pipeline.processBatch(messages, backfill: true);
      expect(store().states(), isEmpty, reason: 'not derived during the import');
      expect(store().isDirty, isTrue);
      // The reader derives them once afterwards.
      expect(SubscriptionProjection.rebuildIfNeeded(db.db, _ns), isTrue);
      expect(store().states(), hasLength(1));
      expect(store().isCurrent, isTrue);
    });

    test('an ordinary one-off purchase does not mark the rows dirty', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      derive();
      final before = db.db
          .select('SELECT updated_at FROM v2_subscriptions WHERE namespace=?', [_ns])
          .single['updated_at'];
      send(
        'VM-HDFCBK-S',
        'Rs.250.00 spent on HDFC Bank Card x5678 at SOME CAFE on 05-08-26',
        '2026-08-05',
      );
      final after = db.db
          .select('SELECT updated_at FROM v2_subscriptions WHERE namespace=?', [_ns])
          .single['updated_at'];
      expect(after, before);
      expect(store().isCurrent, isTrue);
    });

    test('a spend at a shop that now repeats marks the rows dirty', () {
      for (final (d, day) in [
        ('05-08-26', '2026-08-05'),
        ('05-09-26', '2026-09-05'),
      ]) {
        send(
          'VM-HDFCBK-S',
          'Rs.649.00 spent on HDFC Bank Card x5678 at NETFLIX on $d',
          day,
        );
      }
      derive();
      expect(store().states(), isEmpty, reason: 'two charges are not a pattern yet');
      send(
        'VM-HDFCBK-S',
        'Rs.649.00 spent on HDFC Bank Card x5678 at NETFLIX on 05-10-26',
        '2026-10-05',
      );
      expect(store().isDirty, isTrue);
      derive();
      final rows = store().states();
      expect(rows.single.kind, SubscriptionStateKind.pattern);
      expect(rows.single.chargeCount, 3);
    });
  });

  group('rows the capture path did not write', () {
    test('markDirty makes the next reader re-derive, once', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      store().markDirty();
      expect(store().isCurrent, isFalse);
      expect(SubscriptionProjection.rebuildIfNeeded(db.db, _ns), isTrue);
      expect(store().isCurrent, isTrue);
      expect(SubscriptionProjection.rebuildIfNeeded(db.db, _ns), isFalse);
    });

    test('an account that never built rows is derived on first read', () async {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      db.db.execute('DELETE FROM v2_subscriptions');
      db.db.execute("DELETE FROM v2_sync_state WHERE key LIKE 'subscriptions_%'");
      expect(store().isBuilt, isFalse);
      await rebuildSubscriptionsOffThread(db, _ns);
      expect(store().isCurrent, isTrue);
      expect(store().states(), hasLength(1));
    });

    // The phone's database is a file, so the rebuild really runs in a worker
    // isolate there. An in-memory database (everything above) skips the isolate,
    // which once hid a closure that could not be sent to it.
    test('on a file-backed database the rebuild runs in a worker isolate', () async {
      final dir = await Directory.systemTemp.createTemp('pandapay-subs-');
      addTearDown(() => dir.delete(recursive: true));
      final file = AppDatabase.openUnencryptedFileForTesting('${dir.path}/app.sqlite');
      final fileFinancial = FinancialStore(file);
      addTearDown(() {
        fileFinancial.dispose();
        file.close();
      });
      final json = (jsonDecode(jsonEncode(testRuleBundle().toJson())) as Map).cast<String, Object?>();
      json['solverPack'] =
          (jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync()) as Map).cast<String, Object?>();
      final filePipeline = SmsV2Pipeline(
        financial: fileFinancial,
        namespace: _ns,
        bundle: RuleBundle.fromJson(json),
        appVersion: '2.0.0',
      );
      filePipeline.process(
        SmsMessage(
          sender: 'AX-AXISBK-S',
          body: mandate,
          sourceKey: 'f'.padLeft(64, '0'),
          observedAt: DateTime.utc(2026, 8, 1, 6),
        ),
      );
      final fileStore = SubscriptionStore(file.db, namespace: _ns);
      expect(fileStore.isDirty, isTrue);
      file.db.execute('DELETE FROM v2_subscriptions');
      file.db.execute("DELETE FROM v2_sync_state WHERE key LIKE 'subscriptions_%'");
      expect(fileStore.isBuilt, isFalse);
      await rebuildSubscriptionsOffThread(file, _ns);
      expect(fileStore.isCurrent, isTrue);
      expect(fileStore.states(), hasLength(1));
      // Starting a worker isolate is slow when other sessions are running tests.
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a projection version bump re-derives every phone once', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      db.db.execute(
        "UPDATE v2_sync_state SET value='0' WHERE key='subscriptions_projection_version'",
      );
      expect(store().isCurrent, isFalse);
      SubscriptionProjection.rebuildIfNeeded(db.db, _ns);
      expect(store().isCurrent, isTrue);
    });
  });

  const revoke =
      'AutoPay mandate for NETFLIX has been revoked successfully. -Axis Bank';

  group('a rebuild that raced a change (lost update)', () {
    test('rows from an older rebuild neither overwrite a later cancellation nor clear dirty', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      derive();
      final now = DateTime.utc(2026, 9, 10);
      expect(
        seriesFromSubscriptionStates(store().states(), now).single.lifecycleStatus,
        'active',
      );

      // An older rebuild starts: it reads the counter, then the ledger...
      final seqAtStart = store().seq;
      final facts = FactStore(db.db, namespace: _ns).all();
      final events = EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900));
      final olderStates = subscriptionStatesFromLedger(facts, events);
      final olderHistory = subscriptionHistoryFromLedger(facts, events, now: now);

      // ...and before it writes, the cancellation is captured.
      send('AX-AXISBK-S', revoke, '2026-09-02');
      expect(store().isDirty, isTrue);
      expect(store().seq, greaterThan(seqAtStart));

      final saved = store().replaceAll(
        olderStates,
        olderHistory,
        basedOnSeq: seqAtStart,
      );
      expect(saved, isFalse, reason: 'the ledger moved since it was read');
      expect(store().isDirty, isTrue, reason: 'an old rebuild must not clear dirty');

      // The next rebuild reads the newer ledger and shows the cancellation.
      SubscriptionProjection.rebuildIfNeeded(db.db, _ns);
      expect(store().isCurrent, isTrue);
      expect(
        seriesFromSubscriptionStates(store().states(), now).single.lifecycleStatus,
        'cancelled',
      );
    });

    test('with the counter unchanged the swap is saved and clears dirty', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      final seq = store().seq;
      expect(store().isDirty, isTrue);
      expect(
        store().replaceAll(
          const [SubscriptionState(kind: SubscriptionStateKind.mandate, key: 'A', name: 'A')],
          const {},
          basedOnSeq: seq,
        ),
        isTrue,
      );
      expect(store().isCurrent, isTrue);
    });

    test('every markDirty moves the counter, per account', () {
      final before = store().seq;
      store().markDirty();
      store().markDirty();
      expect(store().seq, before + 2);
      expect(store('user:other').seq, 0);
    });

    test('a caller that arrives while a rebuild runs gets a rebuild that sees its change', () async {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      final first = rebuildSubscriptionsOffThread(db, _ns);
      // The cancellation is captured while the first rebuild is still in flight.
      send('AX-AXISBK-S', revoke, '2026-09-02');
      final second = rebuildSubscriptionsOffThread(db, _ns);
      await Future.wait([first, second]);
      expect(store().isCurrent, isTrue);
      expect(
        seriesFromSubscriptionStates(store().states(), DateTime.utc(2026, 9, 10))
            .single
            .lifecycleStatus,
        'cancelled',
      );
    });
  });

  group('capture never fails because of subscriptions', () {
    test('a stored fact the derivation cannot read does not fail or roll back the chunk', () {
      db.db.execute(
        'INSERT INTO v2_facts (namespace, fact_id, source_key, fact_type, observed_at, payload) '
        'VALUES (?,?,?,?,?,?)',
        [_ns, 'broken-fact', 'broken-source', 'movement', '2026-01-01T00:00:00Z', '{not json'],
      );
      n++;
      final key = n.toRadixString(16).padLeft(64, '0');
      late bool stored;
      expect(() {
        stored = pipeline.process(
          SmsMessage(
            sender: 'AX-AXISBK-S',
            body: mandate,
            sourceKey: key,
            observedAt: DateTime.utc(2026, 8, 1, 6),
          ),
        );
      }, returnsNormally);
      expect(stored, isTrue, reason: 'the message was captured, not left pending');
      expect(FactStore(db.db, namespace: _ns).forSource(key), isNotEmpty);
      expect(store().isDirty, isTrue, reason: 'left for the lazy rebuild');
      // The derivation itself does fail on that fact, and leaves the rows dirty.
      expect(() => SubscriptionProjection.rebuild(db.db, _ns), throwsA(anything));
      expect(store().isDirty, isTrue);
    });

    test('capture does not derive: the rows are written only by a rebuild', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      expect(
        db.db.select('SELECT * FROM v2_subscriptions WHERE namespace=?', [_ns]),
        isEmpty,
      );
      expect(store().isDirty, isTrue);
    });
  });

  group('what marks the rows dirty', () {
    test('a debit with no mandate reference that joins a known mandate does', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      derive();
      expect(store().isCurrent, isTrue);
      send(
        'VM-HDFCBK-S',
        'Rs.649.00 spent on HDFC Bank Card x5678 at NETFLIX on 05-09-26',
        '2026-09-05',
      );
      expect(store().isDirty, isTrue);
    });

    test('a receipt under the service name (evidence only) does', () {
      send(
        'VM-UNIONB-S',
        'Dear Customer,UPI AutoPay Mandate with MONTHLY is successfully created towards EXAMPLE TEC from 31/03/2026 to 04/03/2036 for Rs.1649.00-Union Bank of India',
        '2026-03-31',
      );
      send(
        'VM-UNIONB-S',
        'Dear Customer, Your account has  been successfully debited with Rs.99.00 on 31/03/2026 towards EXAMPLE TEC UPI AutoPay-Union Bank of India',
        '2026-03-31',
      );
      derive();
      expect(store().isCurrent, isTrue);
      send(
        'VA-RZRPAY-S',
        'Your payment of Rs.99 for the subscription to Example Labs  is successful. Any recurring subscription payments will be automatically charged to your UPI from now - Razorpay',
        '2026-03-31',
      );
      expect(store().isDirty, isTrue);
    });
  });

  group('open screens are told, whichever path stored the messages', () {
    SmsMessage mandateMessage(String key) => SmsMessage(
      sender: 'AX-AXISBK-S',
      body: mandate,
      sourceKey: key.padLeft(64, '0'),
      observedAt: DateTime.utc(2026, 8, 1, 6),
    );

    Future<List<String>> entitiesOf(void Function() work) async {
      final seen = <String>[];
      final sub = financial.changes.listen((c) => seen.add(c.entity));
      work();
      await pumpEventQueue();
      await sub.cancel();
      return seen;
    }

    test('processBatch(backfill: true) called directly notifies subscriptions', () async {
      final seen = await entitiesOf(
        () => pipeline.processBatch([mandateMessage('c1')], backfill: true),
      );
      expect(seen, contains('subscriptions'));
    });

    test('a live message notifies subscriptions', () async {
      final seen = await entitiesOf(
        () => pipeline.processBatch([mandateMessage('c2')]),
      );
      expect(seen, contains('subscriptions'));
    });

    test('the capture runtime can defer it to the end of a whole import', () async {
      final seen = await entitiesOf(
        () => pipeline.processBatch(
          [mandateMessage('c3')],
          backfill: true,
          deferSubscriptionNotice: true,
        ),
      );
      expect(seen, isNot(contains('subscriptions')));
      expect(store().isDirty, isTrue);
    });
  });

  group('rows that cannot be read', () {
    test('one malformed payload is skipped; the others are still returned', () {
      store().replaceAll(
        const [SubscriptionState(kind: SubscriptionStateKind.mandate, key: 'GOOD', name: 'GOOD')],
        const {},
      );
      db.db.execute(
        'INSERT INTO v2_subscriptions (namespace, series_id, kind, name, payload, updated_at) '
        "VALUES (?, 'v2:bad', 'mandate', 'BAD', '{not json', '2026-01-01T00:00:00Z')",
        [_ns],
      );
      expect([for (final s in store().states()) s.key], ['GOOD']);
    });
  });

  group('upgrading a database that already has rows', () {
    // The SMS module's own counter. A phone upgrades from whatever it had.
    Database openWithRows() {
      final old = sqlite3.openInMemory();
      addTearDown(old.dispose);
      SmsV2Schema.ensure(old);
      old.execute(
        "INSERT INTO v2_facts (namespace, fact_id, source_key, fact_type, observed_at, payload) VALUES ('a','f1','s1','movement','2026-08-01T00:00:00Z','{}')",
      );
      old.execute(
        "INSERT INTO v2_events (namespace, event_id, type, status, payload, dirty) VALUES ('a','e1','purchase','complete','{}',0)",
      );
      old.execute(
        "INSERT INTO v2_sync_state (namespace, key, value) VALUES ('a','k','v')",
      );
      return old;
    }

    void downTo(Database old, int version) {
      old.execute('DROP TABLE v2_subscriptions');
      old.execute('DROP TABLE v2_subscription_history');
      old.execute("UPDATE sms_v2_schema_version SET version=$version WHERE module='sms_v2'");
    }

    void expectKept(Database old) {
      expect(SmsV2Schema.installedVersion(old), 4);
      expect(old.select('SELECT fact_id FROM v2_facts').single['fact_id'], 'f1');
      expect(old.select('SELECT event_id FROM v2_events').single['event_id'], 'e1');
      expect(old.select('SELECT key FROM v2_sync_state').single['key'], 'k');
      expect(old.select('SELECT * FROM v2_subscriptions'), isEmpty);
      expect(old.select('SELECT * FROM v2_subscription_history'), isEmpty);
    }

    test('a version 3 database with facts and events keeps them on the way to 4', () {
      final old = openWithRows();
      downTo(old, 3);
      SmsV2Schema.ensure(old);
      expectKept(old);
    });

    test('a version 2 database (before the shop-key columns) reaches 4 with its rows', () {
      final old = openWithRows();
      // Rewind the facts table to its version 2 shape: no key columns or indexes.
      for (final index in [
        'idx_v2_facts_merchant',
        'idx_v2_facts_instrument',
        'idx_v2_facts_rule',
        'idx_v2_facts_unkeyed',
      ]) {
        old.execute('DROP INDEX $index');
      }
      for (final column in ['merchant_key', 'rule_id', 'keyed']) {
        old.execute('ALTER TABLE v2_facts DROP COLUMN $column');
      }
      downTo(old, 2);
      SmsV2Schema.ensure(old);
      expectKept(old);
      expect(
        old.select("SELECT name FROM pragma_table_info('v2_facts')").map((r) => r['name']),
        containsAll(['merchant_key', 'rule_id', 'keyed']),
      );
    });

    test('a database that never had the module reaches 4', () {
      final fresh = sqlite3.openInMemory();
      addTearDown(fresh.dispose);
      expect(SmsV2Schema.installedVersion(fresh), isNull);
      SmsV2Schema.ensure(fresh);
      expect(SmsV2Schema.installedVersion(fresh), 4);
    });

    test('ensure twice changes nothing and keeps the rows', () {
      final old = openWithRows();
      downTo(old, 3);
      SmsV2Schema.ensure(old);
      SmsV2Schema.ensure(old);
      expectKept(old);
    });
  });
}
