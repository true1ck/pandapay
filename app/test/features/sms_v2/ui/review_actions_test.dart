import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/ui/review_controller.dart';
import 'package:pandapay/features/sms_v2/ui/instrument_actions.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late List<LocalReviewItem> items;
  const namespace = 'user:review';
  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
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
    final intake = SmsIntakeRepository(database);
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    );
    items = [];
    for (var index = 0; index < 2; index++) {
      final source = '${index + 1}' * 64;
      final message = SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: source,
        observedAt: DateTime.utc(2026, 11, index + 1, 7),
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
      pipeline.process(message);
      database.db.execute(
        "INSERT OR REPLACE INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)",
        [
          namespace,
          source,
          'template',
          jsonEncode({'sourceKey': source, 'templateHash': 'same'}),
          'open',
        ],
      );
      items.add(
        LocalReviewItem(
          id: source,
          kind: 'template',
          payload: {'sourceKey': source, 'templateHash': 'same'},
          message: intake.capturedById(namespace, source),
        ),
      );
    }
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });
  ReviewController controller() => ReviewController(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
  );
  test(
    'confirming a format locks every reading without reporting a false defect',
    () {
      controller().apply(
        items: items,
        kind: CorrectionKind.wrongLink,
        confirm: true,
      );
      expect(
        EventStore(database.db, namespace: namespace)
            .listSince(DateTime.utc(1900))
            .every((e) => e.status == EventStatus.userConfirmed),
        isTrue,
      );
      expect(
        database.db.select(
          "SELECT * FROM v2_review_items WHERE namespace=? AND status='open'",
          [namespace],
        ),
        isEmpty,
      );
      expect(
        OutboxStore(
          database.db,
          namespace: namespace,
        ).due(DateTime.now()).where((i) => i.kind == 'correction'),
        isEmpty,
      );
    },
  );
  test('not financial removes all messages in a format from local totals', () {
    controller().apply(items: items, kind: CorrectionKind.notFinancial);
    expect(LedgerStore(database.db, namespace: namespace).list(), isEmpty);
    expect(
      OutboxStore(
        database.db,
        namespace: namespace,
      ).due(DateTime.now()).where((i) => i.kind == 'correction'),
      hasLength(2),
    );
  });
  test('not mine stops existing and future matches from counting', () {
    final instruments = InstrumentStore(database.db, namespace: namespace);
    final detected = instruments.list().single;
    InstrumentActions(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
    ).reject(detected.instrumentId);
    expect(
      instruments.get(detected.instrumentId)!.status,
      InstrumentStatus.rejected,
    );
    expect(LedgerStore(database.db, namespace: namespace).list(), isEmpty);
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    ).process(
      SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: 'f' * 64,
        observedAt: DateTime.utc(2026, 11, 4, 7),
      ),
    );
    expect(LedgerStore(database.db, namespace: namespace).list(), isEmpty);
  });

  test(
    'choosing a duplicate match keeps one anchor and retires the other event',
    () {
      final events = EventStore(
        database.db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900));
      final target = events.first;
      final other = events.last;
      final source =
          database.db.select(
                'SELECT source_key FROM v2_facts WHERE namespace=? AND fact_id=?',
                [namespace, other.eventId],
              ).single['source_key']
              as String;
      controller().apply(
        items: [
          LocalReviewItem(
            id: 'synthetic-link',
            kind: 'link',
            payload: {
              'sourceKey': source,
              'eventId': other.eventId,
              'linkRuleId': 'LINK-DUPLICATE',
            },
          ),
        ],
        kind: CorrectionKind.wrongLink,
        corrected: {
          '_matchEventId': target.eventId,
          '_candidateFactId': target.legs.first.factId,
          '_candidateRole': target.legs.first.role.wire,
        },
      );
      expect(
        LedgerStore(database.db, namespace: namespace).list(),
        hasLength(1),
      );
      final stored = EventStore(database.db, namespace: namespace);
      expect(stored.get(other.eventId)!.type, EventType.unknown);
      expect(stored.get(target.eventId)!.legs, hasLength(2));
      expect(stored.get(target.eventId)!.legs.first.factId, target.eventId);
    },
  );
}
