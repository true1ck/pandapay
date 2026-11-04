import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/migration/history_category_recheck.dart';
import 'package:pandapay/features/sms_v2/migration/history_update.dart';
import 'package:pandapay/features/sms_v2/category/user_category_rules.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle original;
  late RuleBundle revised;
  const namespace = 'user:history-recheck';
  final from = DateTime.utc(2026, 11);
  final to = DateTime.utc(2026, 12);

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    original = testRuleBundle();
    final json = original.toJson();
    json['categoryRules'] = [
      {
        'merchantKey': 'SWIGGY',
        'match': 'token',
        'senders': ['*'],
        'context': [],
        'source': 'catalogue',
        'priority': 99999,
        'category': 'groceries',
      },
    ];
    revised = RuleBundle.fromJson(json);
    for (var index = 0; index < 3; index++) {
      SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: original,
        appVersion: '2.0.0',
      ).process(
        SmsMessage(
          sourceKey: '${index + 1}'.padLeft(64, '0'),
          sender: 'VM-HDFCBK-S',
          body:
              'Sent Rs.${499 + index}.00 From HDFC Bank A/C **1797 to SWIGGY UPI on 10-11-26. Avl Bal Rs.12,345.67',
          observedAt: from.add(Duration(days: 9, minutes: index)),
        ),
        backfill: true,
      );
    }
    // These tests model already-synced history. A separate regression below
    // covers a money record that has not reached the server yet.
    database.db.execute('DELETE FROM v2_outbox');
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  HistoryCategoryRecheck job({bool Function()? current}) =>
      HistoryCategoryRecheck(
        financial: financial,
        namespace: namespace,
        bundle: revised,
        from: from,
        to: to,
        accountIsCurrent: current ?? () => true,
      );
  LedgerStore ledger() => LedgerStore(database.db, namespace: namespace);

  test('a later explicit request uses a new personal category rule', () async {
    await job().run();
    UserCategoryRules(database, namespace: namespace).saveChoice(
      merchantKey:
          financial.entities(namespace, 'transactions').first['merchant_name']
              as String,
      slug: 'fuel',
    );
    expect((await job().run()).changed, 3);
    expect(
      ledger().list().map((entry) => entry.category),
      everyElement('fuel'),
    );
  });

  test(
    'an unsent money record waits for sync before category-only refresh',
    () async {
      final entry = ledger().list().first;
      final queue = OutboxStore(database.db, namespace: namespace);
      queue.enqueue('ledger', entry.entryId, entry.toJson(), backfill: true);
      final report = await job().run();
      expect(report.data['awaitingSync'], 1);
      expect(report.changed, 2);
      final original = queue
          .due(DateTime.now())
          .singleWhere((row) => row.id == 'ledger:${entry.entryId}');
      expect(original.categoryOnly, isFalse);
      expect(original.json, entry.toJson());
      queue.acknowledge(original);
      expect((await job().run()).changed, 1);
    },
  );

  test(
    'a custom display category is preserved even without a ledger override',
    () async {
      final row = financial.entities(namespace, 'transactions').first;
      database.db.execute(
        "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
        [
          jsonEncode({
            ...row,
            'user_category_id': 'custom-category',
            'category_id': null,
            'category_name': 'My choice',
          }),
          namespace,
          row['id'],
        ],
      );
      final eventId = row['event_id'] as String;
      final old = ledger().categoryDecisions()[eventId]!.slug;
      final report = await job().run();
      expect(report.preservedUser, 1);
      expect(ledger().categoryDecisions()[eventId]!.slug, old);
      final after = financial
          .entities(namespace, 'transactions')
          .singleWhere((r) => r['id'] == row['id']);
      expect(after['user_category_id'], 'custom-category');
      expect(after['category_id'], isNull);
      expect(after['category_name'], 'My choice');
    },
  );

  test(
    'preview changes automatic categories without modifying the account',
    () async {
      expect(ledger().list(), hasLength(3));
      final before = database.db
          .select('SELECT payload FROM v2_ledger')
          .map((r) => r['payload'])
          .toList();
      final preview = await job().preview();
      expect(preview.changed, 3);
      expect(
        database.db
            .select('SELECT payload FROM v2_ledger')
            .map((r) => r['payload'])
            .toList(),
        before,
      );
    },
  );

  test('apply is scoped, preserves money and queues backfill once', () async {
    final money = ledger().list().map((e) => e.amountMinor).toList();
    final request = job();
    final report = await request.run(chunkSize: 1);
    expect(report.complete, isTrue);
    expect(report.changed, 3);
    expect(ledger().list().map((e) => e.category), everyElement('groceries'));
    expect(ledger().list().map((e) => e.amountMinor), money);
    final queue = OutboxStore(database.db, namespace: namespace);
    final pending = queue
        .due(DateTime.now())
        .where((r) => r.kind == 'ledger')
        .toList();
    expect(pending, hasLength(3));
    expect(pending.every((r) => r.backfill), isTrue);
    final saved = database.db
        .select('SELECT * FROM v2_outbox')
        .map((r) => r.values.toList())
        .toList();
    final repeated = await job().run(chunkSize: 1);
    expect(repeated.complete, isTrue);
    expect(repeated.changed, 0);
    expect(repeated.data['alreadyApplied'], isTrue);
    expect(
      database.db
          .select('SELECT * FROM v2_outbox')
          .map((r) => r.values.toList())
          .toList(),
      saved,
    );
  });

  test('resume preserves a category chosen between chunks', () async {
    final paused = await job().run(
      chunkSize: 1,
      shouldContinue: () =>
          ledger().list().where((r) => r.category == 'groceries').isEmpty,
    );
    expect(paused.complete, isFalse);
    final id = ledger()
        .list()
        .firstWhere((entry) => entry.category != 'groceries')
        .eventId;
    final entries = ledger().forEvent(id);
    ledger().replaceForEvent(
      id,
      entries,
      category: const CategoryDecision(
        slug: 'fuel',
        source: CategorySource.user,
        confidence: 1,
      ),
    );
    final report = await job().run(chunkSize: 1);
    expect(report.complete, isTrue);
    expect(report.preservedUser, 1);
    expect(ledger().categoryDecisions()[id]!.slug, 'fuel');
  });

  test('account changes stop before a second chunk', () async {
    var current = true;
    await expectLater(
      job(
        current: () => current,
      ).run(chunkSize: 1, onProgress: (_) => current = false),
      throwsStateError,
    );
    expect(
      ledger().list().where((e) => e.category == 'groceries'),
      hasLength(1),
    );
  });

  test('a period outside the history changes nothing', () async {
    final report = await HistoryCategoryRecheck(
      financial: financial,
      namespace: namespace,
      bundle: revised,
      from: to,
      to: DateTime.utc(2027),
      accountIsCurrent: () => true,
    ).run();
    expect(report.changed, 0);
  });

  test(
    'a failed display write rolls back ledger, queue and checkpoint',
    () async {
      final before = ledger().list().map((entry) => entry.toJson()).toList();
      database.db.execute(
        "CREATE TRIGGER fail_history_category BEFORE UPDATE ON financial_entities BEGIN SELECT RAISE(ABORT, 'test write failure'); END",
      );
      await expectLater(
        job().run(chunkSize: 1),
        throwsA(isA<SqliteException>()),
      );
      expect(ledger().list().map((entry) => entry.toJson()).toList(), before);
      database.db.execute('DROP TRIGGER fail_history_category');
      expect((await job().run(chunkSize: 1)).changed, 3);
    },
  );

  test('a later month import gets a new explicit checkpoint', () async {
    await job().run();
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: original,
      appVersion: '2.0.0',
    ).process(
      SmsMessage(
        sourceKey: '4'.padLeft(64, '0'),
        sender: 'VM-HDFCBK-S',
        body:
            'Sent Rs.888.00 From HDFC Bank A/C **1797 to SWIGGY UPI on 15-11-26. Avl Bal Rs.12,345.67',
        observedAt: from.add(const Duration(days: 14)),
      ),
      backfill: true,
    );
    expect(
      ledger().list().where((entry) => entry.category == 'groceries'),
      hasLength(3),
    );
    database.db.execute(
      'DELETE FROM v2_outbox WHERE json_extract(payload,\'\$._categoryOnly\') IS NOT true',
    );
    final report = await job().run();
    expect(report.changed, 1);
    expect(
      ledger().list().where((entry) => entry.category == 'groceries'),
      hasLength(4),
    );
  });

  test(
    'combined preview is isolated and overlapping apply calls serialize',
    () async {
      HistoryUpdate request() => HistoryUpdate(
        financial: financial,
        namespace: namespace,
        bundle: revised,
        appVersion: '2.0.0',
        from: from,
        to: to,
        accountIsCurrent: () => true,
      );
      final before = ledger().list().map((entry) => entry.toJson()).toList();
      final preview = await request().preview();
      expect(preview.categories.changed, 3);
      expect(ledger().list().map((entry) => entry.toJson()).toList(), before);
      expect(
        database.db.select(
          "SELECT 1 FROM sqlite_master WHERE name='sms_v2_migration_state'",
        ),
        isEmpty,
      );
      final results = await Future.wait([request().apply(), request().apply()]);
      expect(results.every((report) => report.categories.complete), isTrue);
      expect(
        ledger().list().where((entry) => entry.category == 'groceries'),
        hasLength(3),
      );
    },
  );
  test('purchase categories follow refunds outside the selected period', () async {
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: original,
      appVersion: '2.0.0',
    );
    pipeline.processBatch([
      SmsMessage(
        sourceKey: 'a' * 64,
        sender: 'VM-HDFCBK-S',
        body:
            'Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00.',
        observedAt: DateTime.utc(2026, 11, 1, 12, 31),
      ),
      SmsMessage(
        sourceKey: 'b' * 64,
        sender: 'VM-HDFCBK-S',
        body:
            'Refund of Rs.499.00 from SWIGGY credited to your HDFC Bank Credit Card XX5678 on 03-11-26.',
        observedAt: DateTime.utc(2026, 11, 3, 10),
      ),
    ], backfill: true);
    database.db.execute('DELETE FROM v2_outbox');
    final report = await HistoryCategoryRecheck(
      financial: financial,
      namespace: namespace,
      bundle: revised,
      from: DateTime.utc(2026, 11, 1),
      to: DateTime.utc(2026, 11, 2),
      accountIsCurrent: () => true,
    ).run();
    expect(report.changed, 2);
    final changed = ledger().list(
      from: DateTime.utc(2026, 11, 1),
      to: DateTime.utc(2026, 11, 4),
    );
    expect(changed, hasLength(2));
    expect(
      changed.map((entry) => ledger().categoryDecisions()[entry.eventId]!.slug),
      everyElement('groceries'),
    );
    final purchase = changed.singleWhere((entry) => entry.isSpend);
    final refund = changed.singleWhere((entry) => !entry.isSpend);
    ledger().replaceForEvent(
      refund.eventId,
      [refund],
      category: const CategoryDecision(
        slug: 'groceries',
        source: CategorySource.user,
        confidence: 1,
      ),
    );
    ledger().replaceForEvent(
      purchase.eventId,
      [
        LedgerEntry.fromJson({
          ...purchase.toJson(),
          'category': 'fuel',
          'categorySource': 'user',
        }),
      ],
      category: const CategoryDecision(
        slug: 'fuel',
        source: CategorySource.user,
        confidence: 1,
      ),
    );
    database.db.execute('DELETE FROM v2_outbox');
    await HistoryCategoryRecheck(
      financial: financial,
      namespace: namespace,
      bundle: revised,
      from: DateTime.utc(2026, 11, 1),
      to: DateTime.utc(2026, 11, 2),
      accountIsCurrent: () => true,
    ).run();
    expect(
      changed.map((entry) => ledger().categoryDecisions()[entry.eventId]!.slug),
      everyElement('fuel'),
    );
  });

  test('display corrections and deletions survive category updates', () async {
    final row = database.db.select(
      "SELECT id,payload FROM financial_entities WHERE namespace=? AND entity='transactions' LIMIT 1",
      [namespace],
    ).single;
    final corrected =
        (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>()
          ..['status'] = 'deleted'
          ..['note'] = 'Keep this note'
          ..['merchant_name'] = 'Corrected merchant'
          ..['amount_inr'] = 123.45;
    database.db.execute(
      "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
      [jsonEncode(corrected), namespace, row['id']],
    );
    await job().run();
    final after =
        jsonDecode(
              database.db.select(
                    "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND id=?",
                    [namespace, row['id']],
                  ).single['payload']
                  as String,
            )
            as Map;
    for (final field in ['status', 'note', 'merchant_name', 'amount_inr']) {
      expect(after[field], corrected[field]);
    }
  });

  test('a thousand-event check yields between bounded chunks', () async {
    final fixture =
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
    final facts = <String, Fact>{};
    final events = <Event>[];
    for (var index = 0; index < 1000; index++) {
      final id = (index + 100).toRadixString(16).padLeft(64, '0');
      final fact = Fact.fromJson({
        ...fixture,
        'factId': id,
        'sourceKey': id,
        'observedAt': from.toIso8601String(),
        'occurredAt': from.toIso8601String(),
      });
      FactStore(database.db, namespace: namespace).insert(fact);
      facts[id] = fact;
      events.add(
        Event(
          eventId: id,
          type: EventType.purchase,
          status: EventStatus.complete,
          legs: [EventLeg(factId: id, role: LegRole.debitLeg)],
          confidence: .99,
          occurredAt: from,
          amountMinor: fact.amounts.first.minor,
        ),
      );
    }
    EventStore(database.db, namespace: namespace).upsertAll(events);
    ProjectionWriter(financial, ledger()).write(
      LedgerSnapshot.project(
        events: events,
        factsById: facts,
        instrumentsById: {},
        bundle: original,
      ),
      factsById: facts,
      instrumentsById: {},
    );
    var ticks = 0, chunks = 0, processed = 0, maximumMicros = 0;
    final clock = Stopwatch()..start();
    var previous = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    try {
      final report = await job().run(
        onProgress: (progress) {
          final now = clock.elapsedMicroseconds;
          final duration = now - previous;
          if (duration > maximumMicros) maximumMicros = duration;
          previous = now;
          expect(progress.processed - processed, lessThanOrEqualTo(25));
          processed = progress.processed;
          chunks++;
        },
      );
      expect(report.complete, isTrue);
      expect(chunks, 41);
      expect(ticks, greaterThan(1));
      stdout.writeln(
        'History check 1003 events in ${clock.elapsedMilliseconds} ms; longest chunk including setup ${maximumMicros / 1000} ms; $ticks event-loop ticks',
      );
    } finally {
      timer.cancel();
    }
  });
}
