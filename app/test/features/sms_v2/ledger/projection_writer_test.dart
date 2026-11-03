import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'writer maps card, category, timestamps and stable identity into the real transaction store',
    () {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      addTearDown(db.db.dispose);
      SmsV2Schema.ensure(db.db);
      final financial = FinancialStore(db);
      final f = Fact.fromJson(
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>(),
      );
      final i = Instrument(
        instrumentId: '00000000-0000-4000-8000-000000000001',
        kind: InstrumentKind.creditCard,
        issuerSlug: f.instrument!.issuerSlug!,
        maskDigits: f.instrument!.maskDigits,
        displayName: 'My card',
        status: InstrumentStatus.confirmed,
        userCardId: '00000000-0000-4000-8000-000000000002',
        firstSeenAt: f.observedAt,
        lastSeenAt: f.observedAt,
        evidenceCount: 1,
      );
      final e = Event(
        eventId: f.factId,
        type: EventType.purchase,
        status: EventStatus.complete,
        legs: [EventLeg(factId: f.factId, role: LegRole.debitLeg)],
        confidence: .99,
        occurredAt: f.effectiveAt,
        amountMinor: f.amounts.first.minor,
      );
      const category = CategoryDecision(
        slug: 'dining',
        source: CategorySource.user,
        confidence: 1,
      );
      final rows = DefaultLedgerProjector().project(
        e,
        {f.factId: f},
        {i.instrumentId: i},
        category,
      );
      final snapshot = LedgerSnapshot(
        entries: rows,
        events: [e],
        categoryByEvent: {e.eventId: category},
      );
      final writer = ProjectionWriter(
        financial,
        LedgerStore(db.db, namespace: 'user:a'),
      );
      writer.write(
        snapshot,
        factsById: {f.factId: f},
        instrumentsById: {i.instrumentId: i},
        categoryIdBySlug: {'dining': 'cat-dining'},
      );
      writer.write(
        snapshot,
        factsById: {f.factId: f},
        instrumentsById: {i.instrumentId: i},
        categoryIdBySlug: {'dining': 'cat-dining'},
      );
      final saved = financial
          .entities('user:a', 'transactions')
          .map(TransactionEntry.fromJson)
          .single;
      expect(saved.id, 'v2:${e.eventId}');
      expect(saved.eventId, e.eventId);
      expect(saved.pipelineVersion, 2);
      expect(saved.sourceKey, f.sourceKey);
      expect(saved.amount.paise, e.amountMinor);
      expect(saved.occurredAt, e.occurredAt);
      expect(saved.smsReceivedAt, f.observedAt);
      expect(saved.userCardId, i.userCardId);
      expect(saved.cardLast4, i.maskDigits);
      expect(saved.accountLast4, isNull);
      expect(saved.instrument, TxnInstrument.creditCard);
      expect(saved.entryKind, TxnEntryKind.spend);
      expect(saved.categoryId, 'cat-dining');
      expect(saved.status, 'active');
      expect(TransactionEntry.fromJson(saved.toJson()).eventId, e.eventId);
      expect(financial.entities('user:b', 'transactions'), isEmpty);
      writer.write(
        LedgerSnapshot(
          entries: [],
          events: [e.copyWith(type: EventType.unknown)],
        ),
        factsById: {f.factId: f},
        instrumentsById: {i.instrumentId: i},
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
  test('future entry kinds stay unknown', () {
    expect(TxnEntryKind.fromJson('something-new'), TxnEntryKind.unknown);
    expect(TxnEntryKind.fromJson('payment'), TxnEntryKind.spend);
  });
}
