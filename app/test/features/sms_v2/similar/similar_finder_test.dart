import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/similar/fact_keys.dart';
import 'package:pandapay/features/sms_v2/similar/similar_finder.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  const namespace = 'user:similar';
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsIntakeRepository intake;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    intake = SmsIntakeRepository(database);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  /// One SMS from the rule's example, [day] November 2026.
  String receive(int day, {String? body}) {
    final source = day.toRadixString(16).padLeft(2, '0') * 32;
    final message = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: body ?? bundle.rules.first.examples.first.body,
      sourceKey: source,
      observedAt: DateTime.utc(2026, 11, day, 7),
    );
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [
        namespace,
        source,
        message.sender,
        message.body,
        message.observedAt.millisecondsSinceEpoch,
      ],
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    ).process(message);
    return source;
  }

  String eventOf(String source) => FactStore(
    database.db,
    namespace: namespace,
  ).forSource(source).whereType<MovementFact>().first.factId;

  group('keys on facts', () {
    test('a machine fact keys on the printed shop and the rule; a fact the person wrote keys on nothing', () {
      final source = receive(1);
      final fact = FactStore(database.db, namespace: namespace)
          .forSource(source)
          .whereType<MovementFact>()
          .single;
      final key = FactKeys.of(fact);
      expect(key.merchantKey, 'SWIGGY');
      expect(key.ruleId, fact.provenance.ruleId);
      final stored = database.db.select(
        'SELECT merchant_key, rule_id, keyed FROM v2_facts WHERE fact_id=?',
        [fact.factId],
      ).single;
      expect(stored['merchant_key'], 'SWIGGY');
      expect(stored['keyed'], 1);
      final written = Fact.fromJson({
        ...fact.toJson(),
        'provenance': {
          ...(fact.toJson()['provenance'] as Map).cast<String, Object?>(),
          'engine': 'user',
          'ruleId': 'USER-CORRECTION',
        },
      });
      expect(FactKeys.of(written).merchantKey, isNull);
      expect(FactKeys.of(written).ruleId, isNull);
    });

    test('facts stored before the columns existed get their keys from the backfill', () {
      receive(1);
      receive(2);
      // Make the database look like it was before this version.
      database.db.execute(
        'UPDATE v2_facts SET merchant_key=NULL, rule_id=NULL, keyed=0',
      );
      final total =
          database.db.select('SELECT COUNT(*) AS n FROM v2_facts').single['n']
              as int;
      expect(total, greaterThanOrEqualTo(2));
      expect(FactKeys.pending(database.db, namespace), total);
      expect(FactKeys.backfill(database.db, namespace, limit: 1), 1);
      expect(FactKeys.pending(database.db, namespace), total - 1);
      expect(FactKeys.backfill(database.db, namespace), total - 1);
      expect(FactKeys.backfill(database.db, namespace), 0);
      expect(
        database.db
            .select(
              "SELECT COUNT(*) AS n FROM v2_facts WHERE fact_type='movement' AND merchant_key='SWIGGY'",
            )
            .single['n'],
        2,
      );
    });

    test('upgrading a version 2 database adds the columns and marks every fact as not yet keyed', () {
      receive(1);
      database.db.execute('DROP INDEX idx_v2_facts_merchant');
      database.db.execute('DROP INDEX idx_v2_facts_instrument');
      database.db.execute('DROP INDEX idx_v2_facts_rule');
      database.db.execute('DROP INDEX idx_v2_facts_unkeyed');
      for (final column in ['merchant_key', 'rule_id', 'keyed']) {
        database.db.execute('ALTER TABLE v2_facts DROP COLUMN $column');
      }
      database.db.execute('DROP TABLE v2_personal_merchant_alias');
      database.db.execute('DROP TABLE v2_bulk_changes');
      database.db.execute('DROP TABLE v2_bulk_change_items');
      database.db.execute(
        "UPDATE sms_v2_schema_version SET version=2 WHERE module='sms_v2'",
      );
      SmsV2Schema.ensure(database.db);
      expect(SmsV2Schema.installedVersion(database.db), SmsV2Schema.version);
      final total =
          database.db.select('SELECT COUNT(*) AS n FROM v2_facts').single['n']
              as int;
      expect(FactKeys.pending(database.db, namespace), total);
      FactKeys.backfill(database.db, namespace);
      expect(FactKeys.pending(database.db, namespace), 0);
    });
  });

  group('finding similar transactions', () {
    test('counts the other transactions from the same printed shop and leaves out the edited one', () {
      final first = receive(1);
      receive(2);
      receive(3);
      final finder = SimilarFinder(database.db, namespace: namespace);
      final criteria = SimilarCriteria.shop('SWIGGY');
      expect(finder.count(criteria), 3);
      expect(finder.count(criteria, excludeEventId: eventOf(first)), 2);
      expect(finder.count(SimilarCriteria.shop('SOMEWHERE ELSE')), 0);
    });

    test('a transaction the person already edited is not offered again', () {
      final first = receive(1);
      final second = receive(2);
      receive(3);
      ReviewController(financial: financial, namespace: namespace, bundle: bundle).apply(
        items: [
          LocalReviewItem(
            id: second,
            kind: 'template',
            payload: {'sourceKey': second},
            message: intake.capturedById(namespace, second),
          ),
        ],
        kind: CorrectionKind.wrongMerchant,
        corrected: const {'merchantName': 'Corner Shop'},
      );
      final finder = SimilarFinder(database.db, namespace: namespace);
      expect(finder.count(SimilarCriteria.shop('SWIGGY')), 2);
      expect(
        finder
            .page(SimilarCriteria.shop('SWIGGY'), limit: 10)
            .map((item) => item.eventId),
        isNot(contains(eventOf(second))),
      );
      expect(first, isNotEmpty);
    });

    test('pages walk from newest to oldest without repeating', () {
      final sources = [for (var day = 1; day <= 5; day++) receive(day)];
      final finder = SimilarFinder(database.db, namespace: namespace);
      final criteria = SimilarCriteria.shop('SWIGGY');
      final seen = <String>[];
      SimilarCursor? after;
      while (true) {
        final page = finder.page(criteria, limit: 2, after: after);
        if (page.isEmpty) break;
        seen.addAll(page.map((item) => item.eventId));
        after = page.last.cursor;
      }
      expect(seen, [for (final source in sources.reversed) eventOf(source)]);
    });

    test('the summary gives the count and the newest examples as the person sees them', () {
      for (var day = 1; day <= 4; day++) {
        receive(day);
      }
      final summary = SimilarFinder(database.db, namespace: namespace).summarize(
        SimilarCriteria.shop('SWIGGY'),
        examples: 2,
      );
      expect(summary.count, 4);
      expect(summary.examples, hasLength(2));
      expect(
        summary.examples.map((e) => e.eventId),
        SimilarFinder(database.db, namespace: namespace)
            .page(SimilarCriteria.shop('SWIGGY'), limit: 2)
            .map((item) => item.eventId),
      );
      expect(summary.examples.first.merchantName, isNotNull);
    });
  });

  group('speed on a large history', () {
    test('count, a page and the plan stay on the index with 40,000 facts', () {
      final db = database.db;
      SmsV2Schema.ensure(db);
      db.execute('BEGIN');
      final facts = db.prepare(
        'INSERT INTO v2_facts(namespace,fact_id,source_key,fact_type,observed_at,instrument_id,payload,merchant_key,rule_id,keyed) VALUES(?,?,?,?,?,?,?,?,?,1)',
      );
      final events = db.prepare(
        'INSERT INTO v2_events(namespace,event_id,type,status,payload,dirty) VALUES(?,?,?,?,?,0)',
      );
      for (var i = 0; i < 40000; i++) {
        final id = 'f${i.toString().padLeft(8, '0')}';
        final at = DateTime.utc(2024).add(Duration(minutes: i * 20)).toIso8601String();
        facts.execute([
          namespace,
          id,
          'src$id',
          'movement',
          at,
          'card-${i % 7}',
          '{}',
          'SHOP ${i % 200}',
          'RULE-${i % 30}',
        ]);
        events.execute([namespace, id, 'purchase', i % 50 == 0 ? 'user_confirmed' : 'complete', '{}']);
      }
      facts.dispose();
      events.dispose();
      db.execute('COMMIT');
      final finder = SimilarFinder(db, namespace: namespace);
      final criteria = SimilarCriteria.shop('SHOP 7');
      final watch = Stopwatch()..start();
      final count = finder.count(criteria);
      final page = finder.page(criteria, limit: 50);
      watch.stop();
      expect(count, 200);
      expect(page, hasLength(50));
      expect(watch.elapsedMilliseconds, lessThan(150));
      final plan = db
          .select(
            'EXPLAIN QUERY PLAN SELECT COUNT(*) FROM v2_facts f JOIN v2_events e ON e.namespace = f.namespace AND e.event_id = f.fact_id '
            "WHERE f.namespace = ? AND e.status != 'user_confirmed' AND e.type != 'unknown' AND f.merchant_key = ?",
            [namespace, 'SHOP 7'],
          )
          .map((row) => row['detail'])
          .join(' | ');
      expect(plan, contains('idx_v2_facts_merchant'));
      expect(plan, isNot(contains('SCAN f')));
    });
  });
}
