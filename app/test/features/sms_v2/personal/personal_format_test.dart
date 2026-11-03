import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_v2/corrections/corrections_service.dart';
import 'package:pandapay/features/sms_v2/personal/personal_format_service.dart';
import 'package:pandapay/features/sms_v2/personal/personal_rule_engine.dart';
import 'package:pandapay/features/sms_v2/personal/personal_rule_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  const namespace = 'user:personal';
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late Instrument instrument;
  late PersonalRuleStore store;
  SmsMessage message(
    String source, {
    String amount = '100.00',
    String merchant = 'ALPHA',
    String date = '2026-11-01',
    String sender = 'VM-SYNTHBK-S',
    String mask = '5678',
    String reference = '123456789012',
  }) => SmsMessage(
    sender: sender,
    body:
        'SYNTHBANK a/c **$mask posted INR $amount to $merchant on $date. Ref $reference',
    observedAt: DateTime.utc(2026, 11, 3),
    sourceKey: source,
  );
  void captured(SmsMessage message) {
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES(?,?,?,?,?)',
      [
        namespace,
        message.sourceKey,
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
  }

  PersonalFieldSpan span(SmsMessage example, String text) => PersonalFieldSpan(
    example.body.indexOf(text),
    example.body.indexOf(text) + text.length,
  );
  PersonalFormatChoice choice(
    SmsMessage example, {
    EventType type = EventType.purchase,
    AmountRole role = AmountRole.posted,
  }) => PersonalFormatChoice(
    sourceKey: example.sourceKey,
    instrumentId: instrument.instrumentId,
    amount: span(example, '100.00'),
    merchant: span(example, 'ALPHA'),
    date: span(example, '2026-11-01'),
    dateFormat: 'yyyy-MM-dd',
    type: type,
    amountRole: role,
    rail: Rail.upi,
  );
  List<String> teach(PersonalFormatChoice selected, Iterable<String> sources) =>
      CorrectionsService(
        financial: financial,
        namespace: namespace,
        bundle: bundle,
      ).teachFormat(choice: selected, sourceKeys: sources, appVersion: '2');
  PersonalRuleEngine engine() => PersonalRuleEngine(
    store: store,
    instruments: InstrumentStore(database.db, namespace: namespace),
  );
  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    SmsIntakeRepository(database);
    bundle = RuleBundle(
      bundleVersion: 0,
      createdAt: DateTime.utc(2026),
      expiresAt: DateTime.utc(2027),
      minEngineVersion: '2.0.0',
      taxonomyVersion: 1,
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      appVersion: '2',
    );
    instrument = Instrument(
      instrumentId: '00000000-0000-4000-8000-000000000001',
      kind: InstrumentKind.bankAccount,
      issuerSlug: 'synthetic',
      maskDigits: '5678',
      displayName: 'Synthetic bank',
      status: InstrumentStatus.confirmed,
      firstSeenAt: DateTime.utc(2026),
      lastSeenAt: DateTime.utc(2026),
      evidenceCount: 1,
    );
    InstrumentStore(database.db, namespace: namespace).upsert(instrument);
    store = PersonalRuleStore(
      SyncStateStore(database.db, namespace: namespace),
    );
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  test(
    'group teaching retains each printed amount merchant/date and creates only user facts without shared stats',
    () {
      final first = message('a');
      final second = message(
        'b',
        amount: '245.65',
        merchant: 'BETA STORE',
        date: '2026-11-02',
      );
      captured(first);
      captured(second);
      expect(teach(choice(first), ['a', 'b']), ['a', 'b']);
      final facts = FactStore(
        database.db,
        namespace: namespace,
      ).since(DateTime.utc(1900)).whereType<MovementFact>().toList();
      expect(facts.map((f) => f.amounts.single.minor).toSet(), {10000, 24565});
      expect(facts.map((f) => f.counterparty!.name).toSet(), {
        'ALPHA',
        'BETA STORE',
      });
      expect(facts.map((f) => f.occurredAt).toSet(), {
        DateTime.utc(2026, 10, 31, 18, 30),
        DateTime.utc(2026, 11, 1, 18, 30),
      });
      expect(facts.every((f) => f.provenance.engine == Engine.user), isTrue);
      expect(
        database.db.select('SELECT * FROM v2_rule_stats_by_account'),
        isEmpty,
      );
      expect(
        LedgerStore(database.db, namespace: namespace).list(),
        hasLength(2),
      );
      expect(
        database.db.select("SELECT * FROM v2_review_items WHERE status='open'"),
        isEmpty,
      );
      expect(
        OutboxStore(
          database.db,
          namespace: namespace,
        ).due(DateTime.now()).any((entry) => entry.kind == 'correction'),
        isFalse,
      );
      final trace =
          jsonDecode(
                SyncStateStore(
                  database.db,
                  namespace: namespace,
                ).get('trace:a')!,
              )
              as Map;
      expect(
        (trace['instruments'] as List).single,
        containsPair('instrumentId', instrument.instrumentId),
      );
      expect(
        (trace['instruments'] as List).single,
        containsPair('step', 'user_choice'),
      );
      expect(
        jsonEncode(store.list().single.toJson()),
        isNot(contains(first.body)),
      );
    },
  );

  test(
    'future messages use saved personal choice before shared extraction but shared ignores still win',
    () {
      final first = message('a');
      captured(first);
      teach(choice(first), ['a']);
      final saved = store.list().single.rule;
      final sharedRule = Rule.fromJson({
        ...saved.toJson(),
        'id': 'NEW-SHARED',
        'emit': [
          {
            ...saved.emit.single.toJson(),
            'attrs': {
              'direction': 'credit',
              'purpose': 'salary',
              'rail': 'upi',
            },
          },
        ],
      });
      final newer = RuleBundle.fromJson({
        ...bundle.toJson(),
        'bundleVersion': 2,
        'signature': {
          'alg': 'Ed25519',
          'keyId': 'synthetic',
          'value': 'c3ludGhldGlj',
        },
        'rules': [sharedRule.toJson()],
      });
      final next = message(
        'future',
        reference: '998877665544',
        amount: '9,999.00',
        merchant: 'GAMMA',
        date: '2026-11-02',
      );
      final parsed = engine().interpretDetailed(next, newer, appVersion: '2');
      expect(parsed.result.ruleVersion, 0);
      expect(parsed.result.ruleId, startsWith('PERSONAL-'));
      expect(
        (parsed.result.facts.single as MovementFact).direction,
        Direction.debit,
      );
      SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: newer,
        appVersion: '2',
        engine: engine(),
        revision: store.revision,
      ).process(next);
      expect(
        FactStore(
          database.db,
          namespace: namespace,
        ).forSource('future').single.amounts.single.minor,
        999900,
      );
      final ignored = RuleBundle.fromJson({
        ...newer.toJson(),
        'ignoreRules': [
          {
            'id': 'IGN-SYNTHETIC',
            'senders': ['SYNTHBK'],
            'pattern': 'SYNTHBANK',
            'flags': '',
            'reason': 'promotion',
          },
        ],
      });
      expect(
        engine()
            .interpretDetailed(next, ignored, appVersion: '2')
            .result
            .outcome,
        InterpretOutcome.ignored,
      );
    },
  );

  test(
    'scope stays with exact sender mask and literal wording and confirmed account',
    () {
      final first = message('a');
      captured(first);
      teach(choice(first), ['a']);
      for (final outside in [
        message('other-sender', sender: 'OTHERBK'),
        message('other-mask', mask: '9999'),
        SmsMessage(
          sender: first.sender,
          body: first.body.replaceFirst('posted', 'failed'),
          observedAt: first.observedAt,
          sourceKey: 'failed',
        ),
      ]) {
        expect(
          engine()
              .interpretDetailed(outside, bundle, appVersion: '2')
              .result
              .outcome,
          InterpretOutcome.unknown,
        );
      }
      final rejected = Instrument.fromJson({
        ...instrument.toJson(),
        'status': 'rejected',
      });
      InstrumentStore(database.db, namespace: namespace).upsert(rejected);
      expect(
        engine()
            .interpretDetailed(message('later'), bundle, appVersion: '2')
            .result
            .outcome,
        InterpretOutcome.unknown,
      );
      expect(
        PersonalRuleStore(
          SyncStateStore(database.db, namespace: 'user:other'),
        ).list(),
        isEmpty,
      );
    },
  );

  test(
    'fixing an existing format replaces each reading without duplicating its event',
    () {
      final first = message('a');
      final wrong = buildPersonalRule(
        message: first,
        instrument: instrument,
        choice: PersonalFormatChoice(
          sourceKey: first.sourceKey,
          instrumentId: instrument.instrumentId,
          amount: span(first, '123456789012'),
          merchant: span(first, 'ALPHA'),
          date: span(first, '2026-11-01'),
          dateFormat: 'yyyy-MM-dd',
          type: EventType.purchase,
          amountRole: AmountRole.posted,
          rail: Rail.upi,
        ),
      );
      bundle = RuleBundle.fromJson({
        ...bundle.toJson(),
        'rules': [wrong.rule.toJson()],
      });
      captured(first);
      captured(message('b', amount: '100.00', reference: '987654321012'));
      final events = EventStore(
        database.db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900));
      expect(events, hasLength(2));
      teach(choice(first), ['a', 'b']);
      final after = EventStore(
        database.db,
        namespace: namespace,
      ).listSince(DateTime.utc(1900));
      expect(
        after.map((e) => e.eventId).toSet(),
        events.map((e) => e.eventId).toSet(),
      );
      expect(after.every((e) => e.status == EventStatus.userConfirmed), isTrue);
      expect(
        LedgerStore(
          database.db,
          namespace: namespace,
        ).list().fold<int>(0, (n, e) => n + e.amountMinor),
        20000,
      );
      expect(
        OutboxStore(
          database.db,
          namespace: namespace,
        ).due(DateTime.utc(2100)).where((e) => e.kind == 'correction'),
        isEmpty,
      );
    },
  );

  test(
    'validate every group member before saving any rule fact ledger or outbox',
    () {
      final first = message('a');
      captured(first);
      captured(message('b', mask: '9999'));
      final previous = OutboxStore(
        database.db,
        namespace: namespace,
      ).due(DateTime.now()).map((e) => e.json).toList();
      expect(() => teach(choice(first), ['a', 'b']), throwsArgumentError);
      expect(store.list(), isEmpty);
      expect(
        FactStore(database.db, namespace: namespace).forSource('a'),
        isEmpty,
      );
      expect(LedgerStore(database.db, namespace: namespace).list(), isEmpty);
      expect(
        OutboxStore(
          database.db,
          namespace: namespace,
        ).due(DateTime.now()).map((e) => e.json),
        previous,
      );
    },
  );

  test('a failed projection rolls back rule and all prior group writes', () {
    final first = message('a');
    captured(first);
    database.db.execute(
      "CREATE TRIGGER synthetic_fail_personal BEFORE INSERT ON v2_events BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END",
    );
    expect(() => teach(choice(first), ['a']), throwsA(isA<SqliteException>()));
    expect(store.list(), isEmpty);
    expect(
      FactStore(database.db, namespace: namespace).forSource('a'),
      isEmpty,
    );
    expect(database.db.select('SELECT * FROM v2_outbox'), isEmpty);
    expect(
      SyncStateStore(database.db, namespace: namespace).get('trace:a'),
      isNot(contains('PERSONAL-')),
    );
  });

  test(
    'cannot teach missing raw source foreign account or an already matched reading',
    () {
      final first = message('a');
      captured(first);
      expect(() => teach(choice(first), ['a', 'missing']), throwsArgumentError);
      final foreign = PersonalFormatChoice(
        sourceKey: 'a',
        instrumentId: 'other',
        amount: span(first, '100.00'),
      );
      expect(() => teach(foreign, ['a']), throwsArgumentError);
      teach(choice(first), ['a']);
      expect(() => teach(choice(first), ['a']), throwsArgumentError);
    },
  );

  for (final type in [
    EventType.income,
    EventType.refund,
    EventType.ownTransfer,
    EventType.investment,
  ]) {
    test(
      'personal ${type.wire} reaches the real linker and ledger classification',
      () {
        final first = message('a');
        captured(first);
        teach(choice(first, type: type), ['a']);
        expect(
          EventStore(
            database.db,
            namespace: namespace,
          ).listSince(DateTime.utc(1900)).single.type,
          type,
        );
        final entry = LedgerStore(
          database.db,
          namespace: namespace,
        ).list().single;
        expect(entry.isSpend, isFalse);
        expect(entry.isInvestment, type == EventType.investment);
      },
    );
  }
  for (final role in [AmountRole.held, AmountRole.released]) {
    test('personal IPO ${role.wire} stays out of spending', () {
      final first = message('a');
      captured(first);
      teach(choice(first, type: EventType.ipoApplication, role: role), ['a']);
      expect(
        FactStore(database.db, namespace: namespace).forSource('a').single,
        isA<HoldFact>(),
      );
      expect(LedgerStore(database.db, namespace: namespace).list(), isEmpty);
    });
  }
  test('field overlap and selecting account digits as amount are rejected', () {
    final first = message('a');
    captured(first);
    final wrong = PersonalFormatChoice(
      sourceKey: 'a',
      instrumentId: instrument.instrumentId,
      amount: span(first, '5678'),
    );
    expect(() => teach(wrong, ['a']), throwsArgumentError);
    final overlap = PersonalFormatChoice(
      sourceKey: 'a',
      instrumentId: instrument.instrumentId,
      amount: span(first, '100.00'),
      merchant: span(first, '100.00'),
    );
    expect(() => teach(overlap, ['a']), throwsArgumentError);
  });
}
