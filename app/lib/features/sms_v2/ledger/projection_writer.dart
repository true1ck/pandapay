import 'package:pandapay_domain/pandapay_domain.dart' show Money, TxnRail;
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart';
import '../storage/ledger_store.dart';

/// Maps the ledger to the existing transaction model. All attribution comes
/// from a money leg; the anchor's source key is kept even if it was a hold.
TransactionEntry? transactionForEvent(
  v2.Event event,
  List<v2.LedgerEntry> entries,
  Map<String, v2.Fact> facts,
  Map<String, v2.Instrument> instruments, {
  v2.CategoryDecision? category,
  Map<String, String> categoryIdBySlug = const {},
  Map<String, String> instrumentIdByFactId = const {},
}) {
  final kind = transactionKindForEvent(event);
  final fact = moneyFactForEvent(event, facts);
  final row = entries.where((e) => e.unit == v2.LedgerUnit.inr).firstOrNull;
  if (kind == null || fact == null || row == null) return null;
  final instrument = instrumentForFact(
    fact,
    instruments,
    instrumentIdByFactId: instrumentIdByFactId,
  );
  final method = switch (instrument?.kind) {
    v2.InstrumentKind.creditCard => TxnInstrument.creditCard,
    v2.InstrumentKind.debitCard => TxnInstrument.debitCard,
    v2.InstrumentKind.bankAccount => TxnInstrument.upiBank,
    v2.InstrumentKind.wallet => TxnInstrument.wallet,
    _ => TxnInstrument.other,
  };
  final slug = category?.slug ?? row.category;
  final external = row.to is v2.ExternalEndpoint
      ? row.to as v2.ExternalEndpoint
      : row.from is v2.ExternalEndpoint
      ? row.from as v2.ExternalEndpoint
      : null;
  final printed = fact.counterparty?.name;
  final merchant =
      fact.purpose == v2.MovementPurpose.walletTopup &&
          event.type == v2.EventType.purchase
      ? external?.counterpartyKey
      : printed ?? external?.counterpartyKey;
  final mask = instrument?.maskDigits;
  final last4 = mask == null
      ? null
      : mask.length > 4
      ? mask.substring(mask.length - 4)
      : mask;
  return TransactionEntry(
    id: 'v2:${event.eventId}',
    eventId: event.eventId,
    pipelineVersion: 2,
    sourceKey: facts[event.eventId]?.sourceKey ?? fact.sourceKey,
    amount: Money.fromPaise(row.amountMinor),
    occurredAt: row.occurredAt,
    merchantName: merchant,
    merchantVpa: fact.counterparty?.vpa,
    categoryId: slug == null
        ? null
        : TaxonomyRegistry.v1.categoryIdForSlug(slug, categoryIdBySlug),
    categoryName: slug == null
        ? null
        : TaxonomyRegistry.v1.categoryFor(slug)?.displayName,
    instrument: method,
    entryKind: TxnEntryKind.fromJson(kind),
    userCardId:
        method == TxnInstrument.creditCard || method == TxnInstrument.debitCard
        ? instrument?.userCardId
        : null,
    cardLast4:
        method == TxnInstrument.creditCard || method == TxnInstrument.debitCard
        ? last4
        : null,
    accountLast4: method == TxnInstrument.upiBank ? last4 : null,
    cardDisplayName: instrument?.displayName,
    rail: switch (fact.rail) {
      v2.Rail.upi => TxnRail.upiQr,
      _ => TxnRail.unknown,
    },
    paymentMethod: fact.rail == v2.Rail.upi ? 'upi' : null,
    source: 'sms',
    smsReceivedAt: fact.observedAt,
    status: 'active',
  );
}

class ProjectionWriter {
  ProjectionWriter(this.financial, this.ledger) {
    if (!identical(financial.database.db, ledger.db)) {
      throw ArgumentError('stores must share a database');
    }
  }
  final FinancialStore financial;
  final LedgerStore ledger;

  /// A savepoint commits ledger and display rows together. An event that no
  /// longer has a money projection retires its old display row.
  void write(
    LedgerSnapshot snapshot, {
    required Map<String, v2.Fact> factsById,
    required Map<String, v2.Instrument> instrumentsById,
    Map<String, String> categoryIdBySlug = const {},
    Map<String, String> instrumentIdByFactId = const {},
  }) {
    final existing = {
      for (final raw in financial.entities(ledger.namespace, 'transactions'))
        if (raw['event_id'] is String)
          raw['event_id'] as String: TransactionEntry.fromJson(raw),
    };
    final rowsByEvent = <String, List<v2.LedgerEntry>>{};
    for (final e in snapshot.entries) {
      rowsByEvent.putIfAbsent(e.eventId, () => []).add(e);
    }
    final db = ledger.db;
    financial.batch(() {
      db.execute('SAVEPOINT v2_projection');
      try {
        final display = <TransactionEntry>[];
        for (final e in snapshot.events) {
          final entries = rowsByEvent[e.eventId] ?? const <v2.LedgerEntry>[];
          ledger.replaceForEvent(
            e.eventId,
            entries,
            category: snapshot.categoryByEvent[e.eventId],
          );
          final row = transactionForEvent(
            e,
            entries,
            factsById,
            instrumentsById,
            category: snapshot.categoryByEvent[e.eventId],
            categoryIdBySlug: categoryIdBySlug,
            instrumentIdByFactId: instrumentIdByFactId,
          );
          final old = existing[e.eventId];
          if (row != null) {
            // Keep server-earned rewards and local display edits on re-projection.
            display.add(
              TransactionEntry.fromJson({
                ...row.toJson(),
                if (old != null) ...{
                  'id': old.id,
                  'expected_value_inr': old.rewardValue?.rupees,
                  'note': old.note,
                  'tags': old.tags.map((t) => t.toJson()).toList(),
                },
              }),
            );
          } else if (old != null) {
            display.add(old.copyWith(status: 'ignored'));
          }
        }
        financial.saveTransactions(ledger.namespace, display);
        db.execute('RELEASE v2_projection');
      } catch (_) {
        db.execute('ROLLBACK TO v2_projection');
        db.execute('RELEASE v2_projection');
        rethrow;
      }
    });
  }
}
