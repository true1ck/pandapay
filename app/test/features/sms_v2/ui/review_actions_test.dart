import 'package:pandapay/features/sms_v2/ui/transaction_actions.dart';
import 'package:pandapay/data/user_cards_repository.dart';
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
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
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
  test(
    'repeated edits use current money but report the original receipt identity',
    () {
      final item = items.first;
      final source = item.payload['sourceKey'] as String;
      final facts = FactStore(database.db, namespace: namespace);
      final original = facts.forSource(source).whereType<MovementFact>().first;
      for (final amount in [10000, 8000, 6000]) {
        controller().apply(
          items: [item],
          kind: CorrectionKind.wrongAmount,
          corrected: {'amountMinor': amount},
        );
        expect(
          LedgerStore(
            database.db,
            namespace: namespace,
          ).forEvent(original.factId).single.amountMinor,
          amount,
        );
      }
      for (final merchant in ['SYNTHETIC FIRST SHOP', 'SYNTHETIC FINAL SHOP']) {
        controller().apply(
          items: [item],
          kind: CorrectionKind.wrongMerchant,
          corrected: {'merchantName': merchant},
        );
      }
      for (final date in ['2026-10-30T07:00:00Z', '2026-10-31T07:00:00Z']) {
        controller().apply(
          items: [item],
          kind: CorrectionKind.wrongDate,
          corrected: {'occurredAt': date},
        );
      }
      final event = EventStore(
        database.db,
        namespace: namespace,
      ).get(original.factId)!;
      final active = moneyFactForEvent(event, {
        for (final leg in event.legs) leg.factId: facts.get(leg.factId)!,
      })!;
      expect(active.amounts.first.minor, 6000);
      expect(active.counterparty!.name, 'SYNTHETIC FINAL SHOP');
      expect(active.occurredAt, DateTime.utc(2026, 10, 31, 7));
      expect(event.legs, hasLength(2));
      expect(event.legs.first.role, LegRole.original);
      expect(
        facts.forSource(source).whereType<MovementFact>().single.toJson(),
        original.toJson(),
      );
      final queued = OutboxStore(
        database.db,
        namespace: namespace,
      ).due(DateTime.now()).where((row) => row.kind == 'correction');
      expect(queued, hasLength(7));
      for (final row in queued) {
        expect(row.json['sourceKey'], source);
        expect(row.json['factIds'], [original.factId]);
      }
      final saved =
          jsonDecode(
                SyncStateStore(
                  database.db,
                  namespace: namespace,
                ).get('trace:$source')!,
              )
              as Map;
      expect(
        (saved['facts'] as List).map((row) => (row as Map)['factId']),
        contains(active.factId),
      );
      expect(
        (saved['facts'] as List).map((row) => (row as Map)['factId']),
        isNot(contains(original.factId)),
      );
      expect(
        saved['userChoices'],
        containsAll(['wrong_amount', 'wrong_merchant', 'wrong_date']),
      );
    },
  );

  test(
    'a grouped correction rolls back refreshed traces and prior successful edits',
    () {
      final source = items.first.payload['sourceKey'] as String;
      final previousTrace = SyncStateStore(
        database.db,
        namespace: namespace,
      ).get('trace:$source');
      final previousFacts = database.db
          .select('SELECT fact_id FROM v2_facts ORDER BY fact_id')
          .map((row) => row['fact_id'])
          .toList();
      final previousLedger = LedgerStore(
        database.db,
        namespace: namespace,
      ).list().map((entry) => entry.toJson()).toList();
      final previousQueue = OutboxStore(
        database.db,
        namespace: namespace,
      ).due(DateTime.now()).map((row) => row.json).toList();
      expect(
        () => controller().apply(
          items: [
            items.first,
            const LocalReviewItem(
              id: 'missing',
              kind: 'event',
              payload: {'sourceKey': 'missing-source'},
            ),
          ],
          kind: CorrectionKind.wrongAmount,
          corrected: {'amountMinor': 8000},
        ),
        throwsArgumentError,
      );
      expect(
        SyncStateStore(database.db, namespace: namespace).get('trace:$source'),
        previousTrace,
      );
      expect(
        database.db
            .select('SELECT fact_id FROM v2_facts ORDER BY fact_id')
            .map((row) => row['fact_id']),
        previousFacts,
      );
      expect(
        LedgerStore(
          database.db,
          namespace: namespace,
        ).list().map((entry) => entry.toJson()),
        previousLedger,
      );
      expect(
        OutboxStore(
          database.db,
          namespace: namespace,
        ).due(DateTime.now()).map((row) => row.json),
        previousQueue,
      );
    },
  );

  test(
    'category and link corrections refresh the source explanation from saved state',
    () {
      final source = items.first.payload['sourceKey'] as String;
      controller().apply(
        items: [items.first],
        kind: CorrectionKind.wrongCategory,
        corrected: {'category': 'groceries'},
      );
      final store = SyncStateStore(database.db, namespace: namespace);
      var saved = jsonDecode(store.get('trace:$source')!) as Map;
      expect(saved['category'], containsPair('source', 'user'));
      expect(saved['category'], containsPair('slug', 'groceries'));
      final events = EventStore(
        database.db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900));
      final target = events.firstWhere(
        (event) => event.eventId != (saved['event'] as Map)['eventId'],
      );
      controller().apply(
        items: [
          LocalReviewItem(
            id: 'merge',
            kind: 'link',
            payload: {'sourceKey': source, 'linkRuleId': 'LINK-DUPLICATE'},
          ),
        ],
        kind: CorrectionKind.wrongLink,
        corrected: {'_matchEventId': target.eventId},
      );
      saved = jsonDecode(store.get('trace:$source')!) as Map;
      expect((saved['event'] as Map)['eventId'], target.eventId);
      expect(saved['userChoices'], contains('wrong_link'));
      expect(
        (saved['event'] as Map)['legs'],
        EventStore(
          database.db,
          namespace: namespace,
        ).get(target.eventId)!.legs.map((leg) => leg.toJson()).toList(),
      );
    },
  );
  test(
    'transaction edit and delete update facts locally and never require legacy HTTP',
    () {
      final original = financial
          .entities(namespace, 'transactions')
          .map(TransactionEntry.fromJson)
          .first;
      final actions = SmsTransactionActions(controller: controller());
      final date = DateTime.utc(2026, 10, 31);
      actions.edit(
        original,
        amountMinor: 7500,
        merchant: 'SYNTH EDITED',
        occurredAt: date,
        eventType: EventType.purchase,
      );
      final updated = financial
          .entities(namespace, 'transactions')
          .map(TransactionEntry.fromJson)
          .singleWhere((r) => r.id == original.id);
      expect(updated.amount.paise, 7500);
      expect(updated.merchantName, 'SYNTH EDITED');
      expect(updated.occurredAt, date);
      actions.hide(updated);
      expect(
        EventStore(
          database.db,
          namespace: namespace,
        ).get(original.eventId!)!.type,
        EventType.unknown,
      );
      expect(
        LedgerStore(
          database.db,
          namespace: namespace,
        ).forEvent(original.eventId!),
        isEmpty,
      );
      actions.restore(updated);
      expect(
        LedgerStore(
          database.db,
          namespace: namespace,
        ).forEvent(original.eventId!).single.amountMinor,
        7500,
      );
    },
  );
}
