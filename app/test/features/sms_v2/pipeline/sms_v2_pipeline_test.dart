import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsV2Pipeline pipeline;
  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: 'user:test',
      bundle: bundle,
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  SmsMessage message({String key = 'a', String? body}) => SmsMessage(
    sender: 'VM-HDFCBK-S',
    body: body ?? bundle.rules.first.examples.first.body,
    sourceKey: key * 64,
    observedAt: DateTime.utc(2026, 11, 1, 7),
  );

  test(
    'real stores receive facts, instruments, events, ledger and display once',
    () {
      final sms = message();
      expect(pipeline.process(sms), isTrue);
      final facts = FactStore(
        db.db,
        namespace: 'user:test',
      ).forSource(sms.sourceKey);
      expect(facts, hasLength(2));
      expect(facts.map((f) => f.factType), contains(FactType.movement));
      final entries = LedgerStore(db.db, namespace: 'user:test').list();
      expect(entries.single.amountMinor, 49900);
      final event = EventStore(
        db.db,
        namespace: 'user:test',
      ).get(entries.single.eventId)!;
      expect(event.type, EventType.purchase);
      final row = financial
          .entities('user:test', 'transactions')
          .map(TransactionEntry.fromJson)
          .single;
      expect(row.amount.paise, 49900);
      expect(row.pipelineVersion, 2);
      final queued = db.db.select(
        "SELECT payload FROM v2_outbox WHERE kind='source'",
      );
      expect(queued, isNotEmpty);
      final upload = jsonDecode(queued.first['payload'] as String) as Map;
      expect(upload.toString(), isNot(contains(sms.body)));
      for (final f in upload['facts'] as List) {
        expect(f['evidence'], isEmpty);
        expect(f['instrument']?['raw'], isNull);
      }
      expect(pipeline.process(sms), isFalse);
      expect(
        FactStore(db.db, namespace: 'user:test').forSource(sms.sourceKey),
        hasLength(2),
      );
      expect(financial.entities('user:test', 'transactions'), hasLength(1));
      expect(
        FactStore(db.db, namespace: 'user:other').forSource(sms.sourceKey),
        isEmpty,
      );
    },
  );

  test(
    'shared intake keeps safety checks and uses only v2 financial effects',
    () {
      final sms = message();
      final capture = SmsImportStore(financial, v2Pipeline: pipeline);
      capture.captureBatch('user:test', [
        QueuedSms(
          sender: sms.sender,
          body: sms.body,
          receivedAt: sms.observedAt,
        ),
        QueuedSms(
          sender: sms.sender,
          body: 'OTP 123456. Do not share.',
          receivedAt: sms.observedAt,
        ),
      ]);
      expect(SmsIntakeRepository(db).pending('user:test'), isEmpty);
      expect(db.db.select('SELECT * FROM v2_events'), hasLength(1));
      expect(
        financial
            .entities('user:test', 'transactions')
            .single['pipeline_version'],
        2,
      );
      expect(db.db.select('SELECT * FROM sms_source_decisions'), hasLength(1));
      expect(
        () => capture.capture(
          'user:other',
          QueuedSms(
            sender: sms.sender,
            body: sms.body,
            receivedAt: sms.observedAt,
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test('background capture defers processing and preserves the raw sender', () {
    final sms = message();
    SmsImportStore(financial, deferToSmsV2: true).capture(
      'user:test',
      QueuedSms(
        sender: 'HDFCBK-S(smsft_fi)',
        body: sms.body,
        receivedAt: sms.observedAt,
      ),
    );
    final retained = SmsIntakeRepository(db).pending('user:test').single;
    expect(retained.message.sender, 'HDFCBK-S(smsft_fi)');
    expect(db.db.select('SELECT * FROM v2_facts'), isEmpty);
    expect(financial.entities('user:test', 'transactions'), isEmpty);
  });

  test('unknown layouts create local template review without raw SMS text', () {
    final sms = message(body: 'An unrecognised financial alert Rs.250.');
    expect(pipeline.process(sms), isTrue);
    expect(LedgerStore(db.db, namespace: 'user:test').list(), isEmpty);
    final review = db.db.select('SELECT payload FROM v2_review_items').single;
    expect(review['payload'], isNot(contains(sms.body)));
    expect(jsonDecode(review['payload'] as String)['sourceKey'], sms.sourceKey);
  });

  test('storage failure rolls back all effects and allows a retry', () {
    db.db.execute(
      "CREATE TRIGGER reject_projection BEFORE INSERT ON v2_ledger BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    expect(() => pipeline.process(message()), throwsA(isA<SqliteException>()));
    expect(db.db.select('SELECT * FROM v2_facts'), isEmpty);
    expect(db.db.select('SELECT * FROM v2_instruments'), isEmpty);
    expect(db.db.select('SELECT * FROM v2_events'), isEmpty);
    expect(db.db.select('SELECT * FROM sms_source_decisions'), isEmpty);
    db.db.execute('DROP TRIGGER reject_projection');
    expect(pipeline.process(message()), isTrue);
  });
}
