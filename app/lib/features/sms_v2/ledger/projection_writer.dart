import 'dart:convert';
import 'package:pandapay_domain/pandapay_domain.dart' show Money, TxnRail;
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart';
import '../personal/owner_identity_store.dart';
import '../personal/personal_merchant_aliases.dart';
import '../storage/ledger_store.dart';
import '../storage/subscription_store.dart';

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
  Map<String, PersonalMerchantAlias> merchantAliases = const {},
  v2.OwnerIdentity? marks,
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
  // The person's own name for this shop wins over the printed one, for SMS
  // received since they chose it. A reading they wrote themselves (an edit) is
  // already their words and is never renamed again.
  final printedName = fact.counterparty?.name;
  final alias = printedName == null || fact.provenance.engine == v2.Engine.user
      ? null
      : merchantAliases[normalizeMerchantText(printedName)];
  final printed = alias != null && alias.appliesTo(fact.observedAt)
      ? alias.name
      : printedName;
  // A card bill is a payment to the user's own card, however it was paid
  // (bank transfer, CHEQ, CRED, BBPS), so it is labelled as one.
  final family =
      event.type == v2.EventType.ownTransfer &&
      !(marks?.isMarkedSelfOnce(fact.sourceKey) ?? false) &&
      (marks?.isFamilyTransfer(
            name: fact.counterparty?.name,
            vpa: fact.counterparty?.vpa,
            mask: fact.counterparty?.accountMask,
            sourceKey: fact.sourceKey,
          ) ??
          false);
  final merchant = event.type == v2.EventType.cardBillPayment
      ? 'Credit card payment'
      // The bank's own cashback credit names no shop; "UNKNOWN" read as a
      // failed parse. It is a reward the bank paid, so say so.
      : event.type == v2.EventType.cashback && printed == null
      ? 'Cashback received'
      : event.type == v2.EventType.ownTransfer && printed == null
      ? (family ? 'Family transfer' : 'Transfer between your accounts')
      : fact.purpose == v2.MovementPurpose.walletTopup &&
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
    transferType: kind != 'transfer'
        ? null
        : switch (event.type) {
            v2.EventType.ownTransfer => family ? 'family' : 'self',
            v2.EventType.cardBillPayment => 'card_bill',
            v2.EventType.walletTopup => 'wallet',
            _ => null,
          },
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
    // How it was paid, only when the message says so. Nothing about spending
    // changes with it; the person can still pick another method.
    paymentMethod: switch (fact.rail) {
      v2.Rail.upi => 'upi',
      v2.Rail.neft => 'neft',
      v2.Rail.imps => 'imps',
      v2.Rail.rtgs => 'rtgs',
      v2.Rail.cheque => 'cheque',
      v2.Rail.nach => 'auto_debit',
      _ => null,
    },
    source: 'sms',
    smsReceivedAt: fact.observedAt,
    status: 'active',
    // A cashback the bank credited is a confirmed reward, not an estimate.
    rewardState: event.type == v2.EventType.cashback ? 'confirmed' : 'estimated',
  );
}

bool _unchanged(TransactionEntry? stored, TransactionEntry row) =>
    stored != null &&
    stored.id == row.id &&
    jsonEncode(stored.toJson()) == jsonEncode(row.toJson());

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
    // A correction, a server pull or a withdrawal changes the ledger without
    // going through capture; the saved subscription rows are then out of date
    // until the next reader re-derives them. Capture passes false because it
    // marks them itself, from the facts it stored.
    bool markSubscriptionsDirty = true,
  }) {
    final merchantAliases = PersonalMerchantAliases(
      ledger.db,
      namespace: ledger.namespace,
    ).load();
    // The payees and single payments the person marked as family or as their
    // own decide the badge a transfer carries (see [OwnerIdentity]).
    final marks = OwnerIdentityStore(
      ledger.db,
      namespace: ledger.namespace,
    ).marksOnly();
    final existing = <String, TransactionEntry>{};
    final legacyBySource = <String, List<TransactionEntry>>{};
    final db = ledger.db;
    db.execute(
      "CREATE INDEX IF NOT EXISTS idx_financial_sms_v2_event ON financial_entities(namespace,json_extract(payload,'\$.event_id')) WHERE entity='transactions'",
    );
    final eventIds = snapshot.events
        .map((event) => event.eventId)
        .toSet()
        .toList();
    final sources = {
      for (final event in snapshot.events)
        if (factsById[event.eventId] case final fact?) fact.sourceKey,
    }.toList();
    final stored = <String, Map<String, dynamic>>{};
    for (final (ids, expression) in [
      (eventIds, "json_extract(payload,'\$.event_id')"),
      (sources, 'source_key'),
    ]) {
      for (var offset = 0; offset < ids.length; offset += 400) {
        final chunk = ids.skip(offset).take(400).toList();
        final placeholders = List.filled(chunk.length, '?').join(',');
        for (final row in db.select(
          "SELECT id,payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND $expression IN ($placeholders)",
          [ledger.namespace, ...chunk],
        )) {
          stored[row['id'] as String] =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        }
      }
    }
    for (final raw in stored.values) {
      final eventId = raw['event_id'];
      if (eventId is String) {
        existing[eventId] = TransactionEntry.fromJson(raw);
      } else if (raw['source_key'] case final String sourceKey) {
        final row = TransactionEntry.fromJson(raw);
        if (row.pipelineVersion == 1 &&
            row.source == 'sms' &&
            row.status == 'active') {
          legacyBySource.putIfAbsent(sourceKey, () => []).add(row);
        }
      }
    }
    final rowsByEvent = <String, List<v2.LedgerEntry>>{};
    for (final e in snapshot.entries) {
      rowsByEvent.putIfAbsent(e.eventId, () => []).add(e);
    }
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
            merchantAliases: merchantAliases,
            marks: marks,
          );
          var old = existing[e.eventId];
          if (old == null && row != null) {
            // Match the server's adoption of a legacy row for the same anchor.
            final candidates = legacyBySource.remove(
              factsById[e.eventId]?.sourceKey,
            );
            if (candidates?.length == 1) old = candidates!.single;
          }
          if (row != null) {
            // Keep server-earned rewards and local display edits on re-projection.
            display.add(
              TransactionEntry.fromJson({
                ...row.toJson(),
                if (old != null) ...{
                  'id': old.id,
                  'expected_value_inr': old.rewardValue?.rupees,
                  'note': old.note,
                  // The person's own choice survives a re-projection, like a
                  // note or a tag does.
                  if (old.excludeFromSpend) 'exclude_from_spend': true,
                  'tags': old.tags.map((t) => t.toJson()).toList(),
                  if (old.userCategoryId != null) ...{
                    'category_id': null,
                    'user_category_id': old.userCategoryId,
                    'category_name': old.categoryName,
                  },
                },
              }),
            );
          } else if (old != null) {
            display.add(old.copyWith(status: 'ignored'));
          }
        }
        // A pull re-projects events whose display row did not change (the same
        // facts, the same ledger). Writing those again costs a receipt upsert,
        // a pending-row delete and a row upsert each, so only rows that
        // differ from what is stored are saved.
        financial.saveTransactions(ledger.namespace, [
          for (final row in display)
            if (!_unchanged(existing[row.eventId], row)) row,
        ]);
        // Unconditional: a correction can move an event OUT of subscription_charge
        // (a wrong-kind fix to p2p_out, a refund, unknown), which the events it
        // writes no longer show.
        if (markSubscriptionsDirty) {
          SubscriptionStore(db, namespace: ledger.namespace).markDirty();
          financial.notifyExternalChanges(ledger.namespace, const ['subscriptions']);
        }
        db.execute('RELEASE v2_projection');
      } catch (_) {
        db.execute('ROLLBACK TO v2_projection');
        db.execute('RELEASE v2_projection');
        rethrow;
      }
    });
  }
}
