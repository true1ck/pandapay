import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/migration/legacy_replay.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';
import '../support/rules.dart';

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  const ns = 'user:legacy-fixture';
  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    bundle = testRuleBundle();
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });
  void seed() {
    final intake = SmsIntakeRepository(database);
    var i = 0;
    for (final name in [
      'card_bill_pair',
      'ipo_block_then_release',
      'cheque_debit',
    ]) {
      final scenario =
          jsonDecode(
                File(
                  '../tools/sms_golden/scenarios/$name.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final raw in scenario['messages'] as List) {
        final sms = QueuedSms(
          sender: raw['sender'] as String,
          body: raw['body'] as String,
          receivedAt: DateTime.parse(raw['observedAt'] as String),
        );
        intake.remember(ns, sms);
        final source = smsSourceKey(ns, sms.sender, sms.body);
        final row = TransactionEntry(
          id: 'old-${i++}',
          sourceKey: source,
          source: 'sms',
          status: 'active',
          amount: Money.fromPaise(10000),
          occurredAt: sms.receivedAt,
          merchantName: 'Legacy reading',
        );
        financial.saveTransactions(ns, [row]);
      }
    }
    financial.saveTransactions(ns, [
      TransactionEntry(
        id: 'manual',
        source: 'manual',
        status: 'active',
        amount: Money.fromPaise(12300),
        occurredAt: DateTime.utc(2026, 11, 10),
      ),
      TransactionEntry(
        id: 'no-body',
        sourceKey: 'e' * 64,
        source: 'sms',
        status: 'active',
        amount: Money.fromPaise(700),
        occurredAt: DateTime.utc(2026, 11, 10),
      ),
    ]);
  }

  LegacyReplay replay({bool Function()? current}) => LegacyReplay(
    financial: financial,
    namespace: ns,
    bundle: bundle,
    appVersion: '2.0.0',
    accountIsCurrent: current ?? () => true,
  );
  test(
    'a bounded request leaves interrupted sources outside its period pending',
    () async {
      seed();
      await expectLater(
        replay().run(chunkSize: 1, onChunk: (_) => throw StateError('pause')),
        throwsStateError,
      );
      final pending = database.db
          .select(
            'SELECT source_key FROM sms_v2_migration_sources WHERE namespace=? AND done=0',
            [ns],
          )
          .map((r) => r['source_key'])
          .toSet();
      expect(pending, isNotEmpty);
      final before = database.db.select(
        'SELECT before_json FROM sms_v2_migration_state WHERE namespace=?',
        [ns],
      ).single['before_json'];
      final report = await replay().run(
        includeNewSources: true,
        from: DateTime.utc(2027),
        to: DateTime.utc(2027, 2),
      );
      expect(report.complete, isFalse);
      expect(report.retainedBodies, 0);
      expect(report.legacyWithoutBody, 0);
      expect(
        database.db
            .select(
              'SELECT source_key FROM sms_v2_migration_sources WHERE namespace=? AND done=0',
              [ns],
            )
            .map((r) => r['source_key'])
            .toSet(),
        pending,
      );
      expect(
        database.db.select(
          'SELECT before_json FROM sms_v2_migration_state WHERE namespace=?',
          [ns],
        ).single['before_json'],
        before,
      );
      expect((await replay().run()).complete, isTrue);
    },
  );
  test(
    'synced explicit categories survive without an unsent edit marker',
    () async {
      seed();
      const chosen = '10000000-0000-4000-8000-000000000001';
      final row = financial
          .entities(ns, 'transactions')
          .singleWhere((row) => row['id'] == 'old-4');
      database.db.execute(
        "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
        [
          jsonEncode({...row, 'user_category_id': chosen}),
          ns,
          'old-4',
        ],
      );
      await LegacyReplay(
        financial: financial,
        namespace: ns,
        bundle: bundle,
        appVersion: '2.0.0',
        categoryIdBySlug: const {'fuel': chosen},
      ).run();
      expect(
        LedgerStore(database.db, namespace: ns).categoryDecisions().values.any(
          (decision) =>
              decision.source == CategorySource.user && decision.slug == 'fuel',
        ),
        isTrue,
      );
    },
  );
  test(
    'explicit history check includes retained SMS arriving after completion',
    () async {
      seed();
      await replay().run();
      final message = QueuedSms(
        sender: 'VM-HDFCBK-S',
        body:
            'Sent Rs.777.00 From HDFC Bank A/C **1797 to SWIGGY UPI on 10-11-26. Avl Bal Rs.12,345.67',
        receivedAt: DateTime.utc(2026, 11, 10),
      );
      final source = smsSourceKey(ns, message.sender, message.body);
      SmsIntakeRepository(database).remember(ns, message);
      financial.saveTransactions(ns, [
        TransactionEntry(
          id: 'late-legacy',
          sourceKey: source,
          source: 'sms',
          status: 'active',
          amount: Money.fromPaise(88800),
          occurredAt: message.receivedAt,
        ),
      ]);
      expect((await replay().run()).retainedBodies, 5);
      final report = await replay().run(
        includeNewSources: true,
        from: DateTime.utc(2026, 11),
        to: DateTime.utc(2026, 12),
      );
      expect(report.retainedBodies, 6);
      expect(
        financial
            .entities(ns, 'transactions')
            .where(
              (row) => row['source_key'] == source && row['status'] == 'active',
            )
            .single['pipeline_version'],
        2,
      );
      expect((await replay().run(includeNewSources: true)).retainedBodies, 6);
      final outside = await replay().run(
        includeNewSources: true,
        from: DateTime.utc(2027),
        to: DateTime.utc(2027, 2),
      );
      expect(outside.retainedBodies, 0);
      expect(outside.legacyWithoutBody, 0);
    },
  );
  test(
    'fixture replay retains originals/manual/no-body rows, removes holds and merges bills',
    () async {
      seed();
      final before = database.db
          .select('SELECT * FROM financial_entities')
          .map((r) => r.values.toList())
          .toList();
      final preview = await replay().dryRun();
      expect(preview.retainedBodies, 5);
      expect(preview.legacyWithoutBody, 1);
      expect(
        database.db
            .select('SELECT * FROM financial_entities')
            .map((r) => r.values.toList())
            .toList(),
        before,
      );
      final report = await replay().run(chunkSize: 2);
      expect(report.complete, isTrue);
      expect((report.data['beforeByMonth'] as Map)['2026-11'], {
        'spendMinor': 63000,
        'incomeMinor': 0,
        'investmentMinor': 0,
        'transactionCount': 7,
      });
      expect((report.data['afterByMonth'] as Map)['2026-11'], {
        'spendMinor': 513000,
        'incomeMinor': 0,
        'investmentMinor': 0,
        'transactionCount': 3,
      });
      expect(report.duplicatesMerged, greaterThanOrEqualTo(1));
      expect(report.holdsRemoved, greaterThanOrEqualTo(1));
      expect(
        financial
            .entities(ns, 'transactions')
            .where((r) => r['id'] == 'manual')
            .single['amount_inr'],
        123,
      );
      expect(
        financial
            .entities(ns, 'transactions')
            .where((r) => r['id'] == 'no-body')
            .single['status'],
        'active',
      );
      expect(
        database.db.select(
          'SELECT * FROM sms_v2_migration_originals WHERE namespace=?',
          [ns],
        ),
        hasLength(7),
      );
      final count = LedgerStore(database.db, namespace: ns).list().length;
      final second = await replay().run();
      expect(second.toJson(), report.toJson());
      expect(LedgerStore(database.db, namespace: ns).list(), hasLength(count));
      expect(jsonEncode(report.toJson()), isNot(contains('body')));
    },
  );
  test(
    'interruption resumes its account checkpoint without repeating the first chunk',
    () async {
      seed();
      var admitted = true;
      await expectLater(
        replay(current: () => admitted).run(
          chunkSize: 1,
          onChunk: (_) {
            admitted = false;
          },
        ),
        throwsStateError,
      );
      final partial =
          database.db.select(
                "SELECT COUNT(*) AS n FROM sms_v2_migration_sources WHERE namespace=? AND done=1",
                [ns],
              ).single['n']
              as int;
      expect(partial, 1);
      final report = await replay().run(chunkSize: 2);
      expect(report.complete, isTrue);
      expect(
        database.db.select(
          "SELECT COUNT(*) AS n FROM sms_v2_migration_sources WHERE namespace=? AND done=1",
          [ns],
        ).single['n'],
        5,
      );
    },
  );
  test(
    'recorded amount merchant category and deleted choices survive replay without correction uploads',
    () async {
      seed();
      final original = financial
          .entities(ns, 'transactions')
          .where((r) => r['id'] == 'old-4')
          .single;
      final source = original['source_key'] as String;
      SyncQueue(database, namespace: ns).enqueueUpdate(
        entity: 'transactions',
        entityId: 'old-4',
        fields: {'amountInr': 88.25, 'merchantName': 'SYNTH EDITED MERCHANT'},
      );
      database.db.execute(
        "UPDATE financial_entities SET payload=json_set(payload,'\$.is_user_modified',json('true'),'\$.category_name','Dining') WHERE namespace=? AND id='old-4'",
        [ns],
      );
      final deleted = financial
          .entities(ns, 'transactions')
          .where((r) => r['id'] == 'old-0')
          .single;
      database.db.execute(
        "UPDATE financial_entities SET payload=json_set(payload,'\$.status','ignored') WHERE namespace=? AND id=?",
        [ns, deleted['id']],
      );
      await replay().run();
      final facts = database.db
          .select('SELECT payload FROM v2_facts WHERE namespace=?', [ns])
          .map(
            (r) => Fact.fromJson(
              (jsonDecode(r['payload'] as String) as Map)
                  .cast<String, Object?>(),
            ),
          )
          .toList();
      expect(
        facts.any(
          (f) =>
              f.provenance.engine == Engine.user &&
              f.amounts.any((a) => a.minor == 8825),
        ),
        isTrue,
      );
      final visible = financial
          .entities(ns, 'transactions')
          .where((r) => r['status'] == 'active' && r['pipeline_version'] == 2)
          .toList();
      expect(
        visible.any(
          (r) =>
              r['merchant_name'] == 'SYNTH EDITED MERCHANT' &&
              r['amount_inr'] == 88.25,
        ),
        isTrue,
      );
      expect(
        database.db.select(
          "SELECT 1 FROM v2_outbox WHERE namespace=? AND kind='correction'",
          [ns],
        ),
        isEmpty,
      );
      expect(
        database.db.select(
          'SELECT choices_json FROM sms_v2_migration_sources WHERE namespace=? AND source_key=?',
          [ns, source],
        ),
        hasLength(1),
      );
      final uploads = database.db.select(
        "SELECT payload FROM v2_outbox WHERE namespace=? AND kind IN ('source','event','ledger','instrument')",
        [ns],
      );
      expect(
        uploads.every(
          (r) =>
              (jsonDecode(r['payload'] as String) as Map)['_backfill'] == true,
        ),
        isTrue,
      );
    },
  );
  test('a failing chunk rolls back originals projection and progress', () async {
    seed();
    SmsV2Schema.ensure(database.db);
    database.db.execute(
      "CREATE TRIGGER migration_fail BEFORE INSERT ON v2_events BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
    );
    await expectLater(replay().run(), throwsA(isA<SqliteException>()));
    expect(
      financial
          .entities(ns, 'transactions')
          .where((r) => r['status'] == 'superseded'),
      isEmpty,
    );
    expect(
      database.db.select(
        'SELECT 1 FROM sms_v2_migration_sources WHERE namespace=? AND done=1',
        [ns],
      ),
      isEmpty,
    );
    database.db.execute('DROP TRIGGER migration_fail');
    expect((await replay().run()).complete, isTrue);
  });

  test(
    'edits and mapped category IDs made after interruption survive resume',
    () async {
      seed();
      var checks = 0;
      await expectLater(
        replay(current: () => ++checks == 1).run(chunkSize: 1),
        throwsStateError,
      );
      final target = financial
          .entities(ns, 'transactions')
          .singleWhere((r) => r['id'] == 'old-4');
      const category = '11111111-1111-4111-8111-111111111111';
      database.db.execute(
        "UPDATE financial_entities SET payload=json_set(payload,'\$.is_user_modified',json('true'),'\$.category_id',?,'\$.category_name','stale label') WHERE namespace=? AND id=?",
        [category, ns, target['id']],
      );
      SyncQueue(database, namespace: ns).enqueueUpdate(
        entity: 'transactions',
        entityId: 'old-4',
        fields: {
          'amountInr': 92.25,
          'merchantName': 'EDITED AFTER INTERRUPTION',
        },
      );
      await LegacyReplay(
        financial: financial,
        namespace: ns,
        bundle: bundle,
        appVersion: '2',
        categoryIdBySlug: const {'dining': category},
      ).run();
      final row = financial
          .entities(ns, 'transactions')
          .singleWhere(
            (r) =>
                r['pipeline_version'] == 2 &&
                r['source_key'] == target['source_key'],
          );
      expect(row['amount_inr'], 92.25);
      expect(row['merchant_name'], 'EDITED AFTER INTERRUPTION');
      expect(row['category_id'], category);
    },
  );

  test(
    'a deletion made after interruption cannot create money on resume',
    () async {
      seed();
      var checks = 0;
      await expectLater(
        replay(current: () => ++checks == 1).run(chunkSize: 1),
        throwsStateError,
      );
      final target = financial
          .entities(ns, 'transactions')
          .singleWhere((r) => r['id'] == 'old-4');
      SyncQueue(
        database,
        namespace: ns,
      ).enqueueDelete(entity: 'transactions', entityId: 'old-4');
      database.db.execute(
        "UPDATE financial_entities SET payload=json_set(payload,'\$.status','deleted') WHERE namespace=? AND id='old-4'",
        [ns],
      );
      await replay().run();
      expect(
        database.db.select(
          'SELECT 1 FROM v2_facts WHERE namespace=? AND source_key=?',
          [ns, target['source_key']],
        ),
        isEmpty,
      );
      expect(
        financial
            .entities(ns, 'transactions')
            .singleWhere((r) => r['id'] == 'old-4')['status'],
        isNot('active'),
      );
    },
  );

  test(
    'a restored legacy transaction is replayed after interruption',
    () async {
      seed();
      final target = financial
          .entities(ns, 'transactions')
          .singleWhere((row) => row['id'] == 'old-4');
      financial.markInactive(ns, 'old-4');
      var checks = 0;
      await expectLater(
        replay(current: () => ++checks == 1).run(chunkSize: 1),
        throwsStateError,
      );
      financial.markActive(ns, 'old-4');

      final report = await replay().run();

      expect(report.complete, isTrue);
      final replacements = financial
          .entities(ns, 'transactions')
          .where(
            (row) =>
                row['pipeline_version'] == 2 &&
                row['status'] == 'active' &&
                row['source_key'] == target['source_key'],
          );
      expect(replacements, hasLength(1));
    },
  );

  test(
    'known bills and declined attempts supersede erroneous legacy spending',
    () async {
      final intake = SmsIntakeRepository(database);
      for (final type in [FactType.billDue, FactType.attempt]) {
        final example = bundle.rules
            .expand((r) => r.examples)
            .firstWhere((e) => e.expectFactTypes.contains(type));
        final sms = QueuedSms(
          sender: example.sender,
          body: example.body,
          receivedAt: DateTime.utc(2026, 11, 20),
        );
        intake.remember(ns, sms);
        financial.saveTransactions(ns, [
          TransactionEntry(
            id: type.wire,
            sourceKey: smsSourceKey(ns, sms.sender, sms.body),
            source: 'sms',
            status: 'active',
            amount: Money.fromPaise(10000),
            occurredAt: sms.receivedAt,
          ),
        ]);
      }
      final report = await replay().run();
      expect(
        financial
            .entities(ns, 'transactions')
            .where((r) => r['status'] == 'active'),
        isEmpty,
      );
      expect(report.data['uncheckedMessages'], 0);
    },
  );

  test(
    'unsupported user category or future date stays intact for review',
    () async {
      seed();
      database.db.execute(
        "UPDATE financial_entities SET payload=json_set(payload,'\$.is_user_modified',json('true'),'\$.category_id','custom-category') WHERE namespace=? AND id='old-4'",
        [ns],
      );
      final report = await replay().run();
      final row = financial
          .entities(ns, 'transactions')
          .singleWhere((r) => r['id'] == 'old-4');
      expect(row['status'], 'active');
      expect(row['category_id'], 'custom-category');
      expect(report.data['uncheckedMessages'], greaterThanOrEqualTo(1));
      expect(
        database.db.select(
          "SELECT 1 FROM v2_review_items WHERE namespace=? AND json_extract(payload,'\$.reason')='legacy_user_choice'",
          [ns],
        ),
        hasLength(1),
      );
    },
  );
}
