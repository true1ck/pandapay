// A correction can move an event OUT of subscription_charge (a wrong-kind fix to
// a person-to-person payment, a refund, unknown). The events the writer then
// stores no longer show it, so the saved subscription rows must be marked dirty
// whatever type the stored events have.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/subscription_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:writer';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late Fact fact;

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
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  LedgerSnapshot snapshotOf(EventType type) => LedgerSnapshot(
    entries: const [],
    events: [
      Event(
        eventId: fact.factId,
        type: type,
        status: EventStatus.complete,
        legs: [EventLeg(factId: fact.factId, role: LegRole.debitLeg)],
        confidence: .99,
        occurredAt: fact.effectiveAt,
        amountMinor: fact.amounts.first.minor,
      ),
    ],
    categoryByEvent: const {},
  );

  void write(EventType type, {bool? markSubscriptionsDirty}) {
    ProjectionWriter(financial, LedgerStore(db.db, namespace: _ns)).write(
      snapshotOf(type),
      factsById: {fact.factId: fact},
      instrumentsById: const {},
      markSubscriptionsDirty: markSubscriptionsDirty ?? true,
    );
  }

  SubscriptionStore store() => SubscriptionStore(db.db, namespace: _ns);

  for (final type in [
    EventType.p2pOut,
    EventType.refund,
    EventType.unknown,
    EventType.subscriptionCharge,
  ]) {
    test('a correction that leaves ${type.wire} events marks the rows dirty and tells the screens', () async {
      final seen = <String>[];
      final sub = financial.changes.listen((c) => seen.add(c.entity));
      addTearDown(sub.cancel);
      write(type);
      await pumpEventQueue();
      expect(store().isDirty, isTrue);
      expect(seen, contains('subscriptions'));
    });
  }

  test('capture passes false because it marks the rows itself', () {
    write(EventType.p2pOut, markSubscriptionsDirty: false);
    expect(store().isDirty, isFalse);
  });
}
