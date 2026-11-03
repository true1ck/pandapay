import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/corrections/corrections_service.dart';
import 'package:pandapay/features/sms_v2/pipeline/trace.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../support/rules.dart';

void main() {
  test(
    'selecting the target card keeps the bank debit and resolves only the transfer destination',
    () {
      final database = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(database);
      addTearDown(() {
        financial.dispose();
        database.db.dispose();
      });
      const ns = 'user:bill-target';
      final bundle = testRuleBundle();
      final json =
          jsonDecode(
                File(
                  '../tools/sms_golden/scenarios/card_bill_via_cheq_no_receipt.json',
                ).readAsStringSync(),
              )
              as Map;
      final raw = (json['messages'] as List).single as Map;
      final message = SmsMessage(
        sender: raw['sender'] as String,
        body: raw['body'] as String,
        observedAt: DateTime.parse(raw['observedAt'] as String),
        sourceKey: 'a' * 64,
      );
      SmsV2Pipeline(
        financial: financial,
        namespace: ns,
        bundle: bundle,
        appVersion: '2',
      ).process(message);
      final instruments = InstrumentStore(database.db, namespace: ns);
      final card = Instrument(
        instrumentId: generateUuidV4(),
        kind: InstrumentKind.creditCard,
        issuerSlug: 'hdfc',
        maskDigits: '5678',
        displayName: 'HDFC card',
        status: InstrumentStatus.confirmed,
        firstSeenAt: message.observedAt,
        lastSeenAt: message.observedAt,
        evidenceCount: 1,
      );
      instruments.upsert(card);
      instruments.upsert(
        Instrument.fromJson({
          ...card.toJson(),
          'instrumentId': generateUuidV4(),
          'issuerSlug': 'sbi',
        }),
      );
      final event = EventStore(
        database.db,
        namespace: ns,
      ).listSince(DateTime.utc(1900)).single;
      final facts = FactStore(
        database.db,
        namespace: ns,
      ).forSource(message.sourceKey);
      final before = LedgerStore(database.db, namespace: ns).list().single;
      expect(before.to, isA<OwnUnresolvedEndpoint>());
      CorrectionsService(
        financial: financial,
        namespace: ns,
        bundle: bundle,
      ).apply(
        SmsCorrection(
          id: 'choose-card',
          sourceKey: message.sourceKey,
          kind: CorrectionKind.wrongInstrument,
          corrected: {'targetInstrumentId': card.instrumentId},
          factIds: [facts.whereType<MovementFact>().single.factId],
          eventId: event.eventId,
          trace: DecisionTrace(
            appVersion: '2',
            engineVersion: '2',
            bundleVersion: 0,
            outcome: 'matched',
            event: event,
            facts: facts,
          ),
        ),
      );
      final after = LedgerStore(database.db, namespace: ns).list().single;
      expect(after.from.toJson(), before.from.toJson());
      expect((after.to as InstrumentEndpoint).instrumentId, card.instrumentId);
      expect(after.isSpend, isFalse);
      expect(after.countsAsTransaction, isFalse);
    },
  );
}
