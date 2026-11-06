import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/corrections/corrections_service.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late Fact fact;
  late Event event;
  late RuleBundle bundle;
  late CorrectionsService service;
  const trace = DecisionTrace(
    appVersion: '1',
    engineVersion: '2.0.0',
    bundleVersion: 1,
    outcome: 'matched',
  );

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    SmsV2Schema.ensure(db.db);
    financial = FinancialStore(db);
    fact = Fact.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    FactStore(db.db, namespace: 'user:a').insert(fact);
    event = Event(
      eventId: fact.factId,
      type: EventType.purchase,
      status: EventStatus.complete,
      legs: [EventLeg(factId: fact.factId, role: LegRole.debitLeg)],
      confidence: .99,
      occurredAt: fact.effectiveAt,
      amountMinor: fact.amounts.first.minor,
    );
    EventStore(db.db, namespace: 'user:a').upsert(event);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  'assets/sms_rules/baseline_bundle.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    ProjectionWriter(financial, LedgerStore(db.db, namespace: 'user:a')).write(
      LedgerSnapshot.project(
        events: [event],
        factsById: {fact.factId: fact},
        instrumentsById: {},
        bundle: bundle,
      ),
      factsById: {fact.factId: fact},
      instrumentsById: {},
    );
    service = CorrectionsService(
      financial: financial,
      namespace: 'user:a',
      bundle: bundle,
    );
  });
  tearDown(() => db.db.dispose());

  SmsCorrection correction(
    CorrectionKind kind,
    Map<String, Object?> corrected, {
    bool consent = false,
  }) => SmsCorrection(
    id: kind.wire,
    sourceKey: fact.sourceKey,
    kind: kind,
    corrected: corrected,
    trace: trace,
    factIds: [fact.factId],
    eventId: event.eventId,
    sharedLearningConsent: consent,
    message: SmsMessage(
      sender: 'HDFCBK',
      body: 'Rs.499 spent on card xx5678 at SWIGGY.',
      observedAt: fact.observedAt,
      sourceKey: fact.sourceKey,
    ),
  );

  test(
    'amount correction replaces the event leg, updates the screen and queues no private values',
    () {
      final change = correction(CorrectionKind.wrongAmount, {
        'amountMinor': 12300,
      });
      service.apply(change);
      service.apply(change);
      final changed = EventStore(
        db.db,
        namespace: 'user:a',
      ).get(event.eventId)!;
      expect(changed.status, EventStatus.userConfirmed);
      expect(changed.legs, hasLength(2));
      expect(changed.legs.first.factId, fact.factId);
      expect(changed.legs.first.role, LegRole.original);
      expect(changed.legs.last.factId, isNot(fact.factId));
      expect(
        LedgerStore(
          db.db,
          namespace: 'user:a',
        ).forEvent(event.eventId).single.amountMinor,
        12300,
      );
      expect(
        financial
            .entities('user:a', 'transactions')
            .map(TransactionEntry.fromJson)
            .single
            .amount
            .paise,
        12300,
      );
      final queued = OutboxStore(db.db, namespace: 'user:a')
          .due(DateTime.now())
          .where((row) => row.kind == 'correction')
          .single
          .json;
      expect(queued['corrected'], {});
      expect(queued.containsKey('redactedTemplate'), isFalse);
      expect(
        OutboxStore(db.db, namespace: 'user:b').due(DateTime.now()),
        isEmpty,
      );
    },
  );

  test(
    'category preference stays local while a reportable category correction is redacted',
    () {
      service.apply(
        correction(CorrectionKind.preferenceOnly, {
          'merchantKey': 'SWIGGY',
          'category': 'dining',
        }),
      );
      expect(
        OutboxStore(
          db.db,
          namespace: 'user:a',
        ).due(DateTime.now()).where((row) => row.kind == 'correction'),
        isEmpty,
      );
      service.apply(
        correction(CorrectionKind.wrongCategory, {
          'merchantKey': 'SWIGGY',
          'category': 'groceries',
        }, consent: true),
      );
      final row = OutboxStore(db.db, namespace: 'user:a')
          .due(DateTime.now())
          .where((row) => row.kind == 'correction')
          .single
          .json;
      expect((row['corrected'] as Map)['category'], 'groceries');
      expect(row['redactedTemplate'], isNot(contains('499')));
      expect(
        LedgerStore(
          db.db,
          namespace: 'user:a',
        ).forEvent(event.eventId).single.category,
        'groceries',
      );
    },
  );

  test('a correction names only the facts that were uploaded', () {
    // An info fact (a balance notice, a top-up) never leaves the phone, so the
    // server cannot find it and would refuse the whole correction for good.
    final info = Fact.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/info.service.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    FactStore(db.db, namespace: 'user:a').insert(info);
    expect(info.factType, FactType.info);
    service.apply(
      SmsCorrection(
        id: 'info-case',
        sourceKey: info.sourceKey,
        kind: CorrectionKind.missing,
        corrected: const {},
        trace: trace,
        factIds: [info.factId],
      ),
    );
    final queued = OutboxStore(db.db, namespace: 'user:a')
        .due(DateTime.now())
        .where((row) => row.kind == 'correction')
        .single
        .json;
    expect(queued['factIds'], isEmpty);
    expect(queued['sourceKey'], info.sourceKey);
  });

  test(
    'a skeleton that still carries an address is not shared, and the correction is sent without a template',
    () {
      service.apply(
        SmsCorrection(
          id: 'email-case',
          sourceKey: fact.sourceKey,
          kind: CorrectionKind.wrongCategory,
          corrected: const {'merchantKey': 'SWIGGY', 'category': 'groceries'},
          trace: trace,
          factIds: [fact.factId],
          eventId: event.eventId,
          sharedLearningConsent: true,
          message: SmsMessage(
            sender: 'HDFCBK',
            // The bank hides part of the address; the part before the @ used
            // to survive redaction and the server refused the correction.
            body:
                'Credit Card XX1234 Statement is sent to ab***@gmail.com. Total of Rs 5,000.00 is due by 30-JUN-26.',
            observedAt: fact.observedAt,
            sourceKey: fact.sourceKey,
          ),
        ),
      );
      final queued = OutboxStore(db.db, namespace: 'user:a')
          .due(DateTime.now())
          .where((row) => row.kind == 'correction')
          .single
          .json;
      expect(queued['redactedTemplate'], isNot(contains('@')));
      expect(queued['redactedTemplate'], contains('<'));
      expect(smsSkeletonIsShareable(queued['redactedTemplate'] as String), isTrue);
    },
  );

  test(
    'not-financial correction removes money and creates a template ignore rule',
    () {
      expect(
        LedgerStore(db.db, namespace: 'user:a').forEvent(event.eventId),
        hasLength(1),
      );
      final change = correction(CorrectionKind.notFinancial, {});
      service.apply(change);
      expect(
        LedgerStore(db.db, namespace: 'user:a').forEvent(event.eventId),
        isEmpty,
      );
      expect(
        SmsLearningFeedback(
          db,
          namespace: 'user:a',
        ).matchesFalseTransactionRuleSync(
          sender: change.message!.sender,
          body: change.message!.body,
        ),
        isTrue,
      );
    },
  );

  test('changing a purchase category reprojects its linked refund too', () {
    final json = fact.toJson();
    final refundFact = Fact.fromJson({
      ...json,
      'factId': 'f' * 64,
      'sourceKey': 'sms:refund',
      'attrs': <String, Object?>{
        ...(json['attrs'] as Map).cast<String, Object?>(),
        'direction': 'credit',
        'purpose': 'refund',
      },
    });
    FactStore(db.db, namespace: 'user:a').insert(refundFact);
    final refund = Event(
      eventId: refundFact.factId,
      type: EventType.refund,
      status: EventStatus.complete,
      legs: [
        EventLeg(factId: refundFact.factId, role: LegRole.reversal),
        EventLeg(factId: fact.factId, role: LegRole.original),
      ],
      confidence: .99,
      occurredAt: fact.effectiveAt,
      amountMinor: fact.amounts.first.minor,
    );
    EventStore(db.db, namespace: 'user:a').upsert(refund);
    service.apply(
      correction(CorrectionKind.wrongCategory, {
        'merchantKey': 'SWIGGY',
        'category': 'groceries',
      }),
    );
    expect(
      LedgerStore(
        db.db,
        namespace: 'user:a',
      ).categoryDecisions()[refund.eventId]?.slug,
      'groceries',
    );
  });

  test('date and merchant user facts change the projected transaction', () {
    service.apply(
      correction(CorrectionKind.wrongDate, {
        'occurredAt': '2026-10-31T18:30:00Z',
      }),
    );
    final saved = financial
        .entities('user:a', 'transactions')
        .map(TransactionEntry.fromJson)
        .single;
    expect(saved.occurredAt, DateTime.utc(2026, 10, 31, 18, 30));
    final changed = EventStore(db.db, namespace: 'user:a').get(event.eventId)!;
    final money = changed.legs.last.factId;
    service.apply(
      SmsCorrection(
        id: 'merchant-correction',
        sourceKey: FactStore(db.db, namespace: 'user:a').get(money)!.sourceKey,
        kind: CorrectionKind.wrongMerchant,
        corrected: {'merchantName': 'SYNTHETIC STORE'},
        trace: trace,
        factIds: [money],
        eventId: event.eventId,
      ),
    );
    expect(
      financial
          .entities('user:a', 'transactions')
          .map(TransactionEntry.fromJson)
          .single
          .merchantName,
      'SYNTHETIC STORE',
    );
  });

  test(
    'wrong-kind, explicit link and duplicate corrections keep stable identity',
    () {
      service.apply(
        correction(CorrectionKind.wrongKind, {'eventType': 'income'}),
      );
      expect(
        financial
            .entities('user:a', 'transactions')
            .map(TransactionEntry.fromJson)
            .single
            .entryKind,
        TxnEntryKind.income,
      );
      service.apply(
        SmsCorrection(
          id: 'unlink',
          sourceKey: fact.sourceKey,
          kind: CorrectionKind.wrongLink,
          corrected: {
            'legs': [
              EventLeg(factId: fact.factId, role: LegRole.creditLeg).toJson(),
            ],
          },
          trace: trace,
          factIds: [fact.factId],
          eventId: event.eventId,
        ),
      );
      expect(
        EventStore(db.db, namespace: 'user:a').get(event.eventId)!.legs,
        hasLength(1),
      );
      service.apply(correction(CorrectionKind.duplicate, {}));
      expect(
        LedgerStore(db.db, namespace: 'user:a').forEvent(event.eventId),
        isEmpty,
      );
      expect(
        financial
            .entities('user:a', 'transactions')
            .map(TransactionEntry.fromJson)
            .single
            .status,
        'ignored',
      );
    },
  );

  test(
    'instrument reassignment is account scoped and updates the ledger endpoint',
    () {
      final instrument = Instrument(
        instrumentId: '00000000-0000-4000-8000-000000000001',
        kind: InstrumentKind.bankAccount,
        issuerSlug: 'synthetic',
        maskDigits: '1234',
        displayName: 'Synthetic account',
        status: InstrumentStatus.confirmed,
        firstSeenAt: fact.observedAt,
        lastSeenAt: fact.observedAt,
        evidenceCount: 1,
      );
      InstrumentStore(db.db, namespace: 'user:b').upsert(instrument);
      final change = correction(CorrectionKind.wrongInstrument, {
        'instrumentId': instrument.instrumentId,
      });
      expect(() => service.apply(change), throwsArgumentError);
      InstrumentStore(db.db, namespace: 'user:a').upsert(instrument);
      service.apply(change);
      expect(
        (LedgerStore(
                  db.db,
                  namespace: 'user:a',
                ).forEvent(event.eventId).single.from
                as InstrumentEndpoint)
            .instrumentId,
        instrument.instrumentId,
      );
      service.apply(
        correction(CorrectionKind.wrongAmount, {'amountMinor': 8000}),
      );
      expect(
        (LedgerStore(
                  db.db,
                  namespace: 'user:a',
                ).forEvent(event.eventId).single.from
                as InstrumentEndpoint)
            .instrumentId,
        instrument.instrumentId,
      );
      final explanation =
          jsonDecode(
                SyncStateStore(
                  db.db,
                  namespace: 'user:a',
                ).get('trace:${fact.sourceKey}')!,
              )
              as Map;
      expect(
        (explanation['instruments'] as List).single,
        containsPair('step', 'user_choice'),
      );
    },
  );

  test(
    'a late failing repeated edit restores the current fact, trace, totals and queue',
    () {
      service.apply(
        correction(CorrectionKind.wrongAmount, {'amountMinor': 8000}),
      );
      final beforeFacts = FactStore(
        db.db,
        namespace: 'user:a',
      ).since(DateTime.utc(1900)).map((fact) => fact.toJson()).toList();
      final beforeEvent = EventStore(
        db.db,
        namespace: 'user:a',
      ).get(event.eventId)!.toJson();
      final beforeTrace = SyncStateStore(
        db.db,
        namespace: 'user:a',
      ).get('trace:${fact.sourceKey}');
      final beforeQueue = OutboxStore(
        db.db,
        namespace: 'user:a',
      ).due(DateTime.now()).map((row) => row.json).toList();
      expect(
        () => service.apply(
          SmsCorrection(
            id: 'late-invalid',
            sourceKey: fact.sourceKey,
            kind: CorrectionKind.wrongAmount,
            corrected: {
              'amountMinor': 6000,
              '_retireEventIds': ['invalid'],
            },
            trace: trace,
            factIds: [fact.factId],
            eventId: event.eventId,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        FactStore(
          db.db,
          namespace: 'user:a',
        ).since(DateTime.utc(1900)).map((fact) => fact.toJson()),
        beforeFacts,
      );
      expect(
        EventStore(db.db, namespace: 'user:a').get(event.eventId)!.toJson(),
        beforeEvent,
      );
      expect(
        SyncStateStore(
          db.db,
          namespace: 'user:a',
        ).get('trace:${fact.sourceKey}'),
        beforeTrace,
      );
      expect(
        OutboxStore(
          db.db,
          namespace: 'user:a',
        ).due(DateTime.now()).map((row) => row.json),
        beforeQueue,
      );
      expect(
        LedgerStore(
          db.db,
          namespace: 'user:a',
        ).forEvent(event.eventId).single.amountMinor,
        8000,
      );
    },
  );

  test('bad corrections roll back local state and queue atomically', () {
    expect(
      () => service.apply(
        correction(CorrectionKind.wrongAmount, {'amountMinor': -1}),
      ),
      throwsArgumentError,
    );
    expect(
      EventStore(db.db, namespace: 'user:a').get(event.eventId)!.status,
      EventStatus.complete,
    );
    expect(
      OutboxStore(db.db, namespace: 'user:a').due(DateTime.now()),
      isEmpty,
    );
  });
}
