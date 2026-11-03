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
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
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

  test(
    'not-financial correction removes money and creates a template ignore rule',
    () {
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
