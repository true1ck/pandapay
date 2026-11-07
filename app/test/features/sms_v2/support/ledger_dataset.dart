// A synthetic account (facts, events, ledger rows, instruments, transactions)
// for the ledger read-model tests and benchmark. Uses only public store APIs,
// so it also compiles against code that predates the read-model cache.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TransactionEntry;
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

const ns = 'user:11111111-1111-4111-8111-111111111111';

String hex(int n) => n.toRadixString(16).padLeft(64, '0');

final _fixtures = <String, Map<String, Object?>>{};

/// A contract fixture, read from disk once (the benchmark builds 20,000 facts).
Map<String, Object?> fixture(String path) => _fixtures[path] ??=
    (jsonDecode(File('../contracts/sms/v2/fixtures/valid/$path').readAsStringSync())
            as Map)
        .cast<String, Object?>();

/// A small but complete account: facts, events, ledger rows (some with a
/// stored category decision, one refund-shaped), instruments and transactions.
class Dataset {
  Dataset(this.n, {this.merchant = 'SWIGGY', this.extraFacts = 0});
  final int n;

  /// Facts without an event (info / unlinked), to reach a realistic count.
  final int extraFacts;
  final String merchant;
  late final AppDatabase database;
  late final ResponseCache cache;
  FinancialStore get store => cache.financialStore;
  late final FactStore facts;
  late final EventStore events;
  late final LedgerStore ledger;
  late final InstrumentStore instruments;

  void open() {
    database = openInMemoryForTesting();
    cache = ResponseCache(database);
    SmsV2Schema.ensure(database.db);
    facts = FactStore(database.db, namespace: ns);
    events = EventStore(database.db, namespace: ns);
    ledger = LedgerStore(database.db, namespace: ns);
    instruments = InstrumentStore(database.db, namespace: ns);
  }

  void close() {
    store.dispose();
    database.close();
  }

  LedgerEntry entryFor(int i, {int amount = 10000, String? category}) =>
      LedgerEntry(
        entryId: hex(0x50000 + i),
        eventId: hex(0x10000 + i),
        from: const OwnUnresolvedEndpoint(InstrumentKind.creditCard),
        to: ExternalEndpoint(merchant),
        amountMinor: amount,
        unit: LedgerUnit.inr,
        occurredAt: DateTime.utc(2026, 11, 1).add(Duration(minutes: i)),
        category: category ?? 'dining',
        categorySource: CategorySource.user,
        countsAsTransaction: true,
        isSpend: true,
        isIncome: false,
        isInvestment: false,
      );

  Event eventFor(int i, {int amount = 10000}) => Event(
    eventId: hex(0x10000 + i),
    type: EventType.purchase,
    status: EventStatus.complete,
    legs: [EventLeg(factId: hex(0x10000 + i), role: LegRole.debitLeg)],
    confidence: 1,
    occurredAt: DateTime.utc(2026, 11, 1).add(Duration(minutes: i)),
    amountMinor: amount,
  );

  Fact factFor(int i) => Fact.fromJson({
    ...fixture('fact/movement.card_spend.json'),
    'factId': hex(0x10000 + i),
    'sourceKey': 'sms:synthetic:$i',
    'observedAt': DateTime.utc(
      2026,
      11,
      1,
    ).add(Duration(minutes: i)).toIso8601String().replaceFirst('.000Z', 'Z'),
    'counterparty': {
      ...(fixture('fact/movement.card_spend.json')['counterparty'] as Map)
          .cast<String, Object?>(),
      'name': merchant,
    },
  });

  TransactionEntry transactionFor(int i, {String? note}) => TransactionEntry(
    id: 'tx-$i',
    eventId: hex(0x10000 + i),
    sourceKey: 'sms:synthetic:$i',
    amount: Money.fromPaise(10000),
    occurredAt: DateTime.utc(2026, 11, 1).add(Duration(minutes: i)),
    merchantName: merchant,
    source: 'sms',
    status: 'active',
    note: note,
  );

  Instrument instrument(int i, {InstrumentStatus? status}) => Instrument.fromJson({
    ...fixture('instrument/credit_card.json'),
    'instrumentId': '3f9d5a52-1c0e-4b4e-9d57-6a7a1b0f2c1$i',
    'maskDigits': '567$i',
    'userCardId': '8a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4$i',
    'status': (status ?? InstrumentStatus.confirmed).wire,
  });

  void seed() {
    database.db.execute('BEGIN');
    for (var i = 0; i < n; i++) {
      facts.insert(factFor(i));
      events.upsert(eventFor(i), dirty: false);
      ledger.replaceForEvent(
        hex(0x10000 + i),
        [entryFor(i)],
        // Every third event carries a stored category decision.
        category: i % 3 == 0
            ? const CategoryDecision(
                slug: 'dining',
                source: CategorySource.user,
                confidence: 1,
              )
            : null,
        dirty: false,
      );
    }
    for (var k = 0; k < extraFacts; k++) {
      facts.insert(factFor(1000000 + k));
    }
    database.db.execute('COMMIT');
    instruments.upsert(instrument(1));
    instruments.upsert(instrument(2));
    store.saveTransactions(ns, [for (var i = 0; i < n; i++) transactionFor(i)]);
  }
}


/// The pre-cache read: the same stores, rows parsed from scratch.
LedgerReadModel plainRead(Dataset d, {bool cachedFacts = false}) {
  final db = d.database.db;
  return LedgerReadModel(
    v2Ready: true,
    ledger: LedgerSnapshot(
      entries: LedgerStore(db, namespace: ns).list(),
      events: [
        for (final row in db.select(
          'SELECT payload FROM v2_events WHERE namespace=?',
          [ns],
        ))
          Event.fromJson(
            (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
          ),
      ]..sort((a, b) {
          final c = a.occurredAt.compareTo(b.occurredAt);
          return c != 0 ? c : a.eventId.compareTo(b.eventId);
        }),
      categoryByEvent: LedgerStore(db, namespace: ns).categoryDecisions(),
    ),
    // Production already reused decoded facts (FactStore.all); the equality
    // test decodes them from scratch so a cache bug cannot hide.
    facts: cachedFacts
        ? FactStore(db, namespace: ns).all()
        : [
            for (final row in db.select(
              'SELECT payload FROM v2_facts WHERE namespace=?',
              [ns],
            ))
              Fact.fromJson(
                (jsonDecode(row['payload'] as String) as Map)
                    .cast<String, Object?>(),
              ),
          ],
    instruments: InstrumentStore(db, namespace: ns).list(),
    transactions: d.store
        .entities(ns, 'transactions')
        .map(TransactionEntry.fromJson)
        .toList(),
  );
}

String describe(LedgerReadModel m) => jsonEncode({
  'v2Ready': m.v2Ready,
  'entries': [for (final e in m.ledger.entries) e.toJson()],
  'events': [for (final e in m.ledger.events) e.toJson()],
  'categories': {
    for (final e in (m.ledger.categoryByEvent.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))))
      e.key: [e.value.slug, e.value.source.wire, e.value.ruleId, e.value.confidence],
  },
  'facts': ([for (final f in m.facts) f.toJson()]
    ..sort((a, b) => (a['factId'] as String).compareTo(b['factId'] as String))),
  'instruments': [for (final i in m.instruments) i.toJson()],
  'transactions': [for (final t in m.transactions) t.toJson()],
});

