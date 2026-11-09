import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart';
import '../category/category_snapshot.dart';
import '../instruments/card_linker.dart';
import '../instruments/instrument_seeder.dart';
import '../ledger/projection_writer.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';

class InstrumentActions {
  const InstrumentActions({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.catalogue = const [],
  });
  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final List<CardProduct> catalogue;

  CardLinkResult? confirm(String id) {
    final current = _owned(id);
    final next = current.copyWith(status: InstrumentStatus.confirmed);
    _write(next);
    if (next.kind != InstrumentKind.creditCard) return null;
    final result =
        InstrumentCardLinker(
          store: InstrumentStore(financial.database.db, namespace: namespace),
          issuerSlugOf: cardIssuerSlugFromCatalogue(catalogue),
          catalogue: catalogue,
        ).link(
          next,
          userCards: financial
              .entities(namespace, 'cards')
              .map(UserCard.fromJson)
              .toList(),
        );
    if (result case CardLinked(:final instrument)) _write(instrument);
    return result;
  }

  void reject(String id) =>
      _write(_owned(id).copyWith(status: InstrumentStatus.rejected));

  /// The existing add-card flow returned this server-created wallet identity.
  void attachCard(String id, UserCard card) {
    final instrument = _owned(id);
    if (instrument.kind != InstrumentKind.creditCard ||
        card.isArchived ||
        card.last4 != instrument.maskDigits ||
        cardIssuerSlugFromCatalogue(catalogue)(card) != instrument.issuerSlug) {
      throw ArgumentError('Choose the matching card for this account');
    }
    _write(
      instrument.copyWith(
        status: InstrumentStatus.confirmed,
        userCardId: card.id,
      ),
    );
  }

  void rename(String id, String name) {
    final value = name.trim();
    if (value.isEmpty || value.length > 80) {
      throw ArgumentError('Use a name of 1 to 80 characters');
    }
    _write(_owned(id).copyWith(displayName: value));
  }

  Instrument _owned(String id) =>
      InstrumentStore(financial.database.db, namespace: namespace).get(id) ??
      (throw ArgumentError('Instrument is not in this account'));

  void _write(Instrument instrument) {
    final db = financial.database.db;
    financial.batch(() {
      db.execute('SAVEPOINT sms_v2_instrument_choice');
      try {
        final store = InstrumentStore(db, namespace: namespace);
        store.upsert(instrument);
        final facts = FactStore(db, namespace: namespace);
        final allFacts = {
          for (final fact in facts.since(DateTime.utc(1900))) fact.factId: fact,
        };
        final affected = EventStore(db, namespace: namespace).findByFactIds([
          for (final row in db.select(
            'SELECT fact_id FROM v2_facts WHERE namespace=? AND instrument_id=?',
            [namespace, instrument.instrumentId],
          ))
            row['fact_id'] as String,
        ]);
        final categories = CategorySnapshot.load(
          financial.database,
          namespace: namespace,
          aliases: bundle.merchantAliases,
        );
        final instruments = {
          for (final row in store.list()) row.instrumentId: row,
        };
        final ledger = LedgerStore(db, namespace: namespace);
        // One full scan of v2_facts, shared by the projection and the writer.
        final instrumentIdByFactId = facts.instrumentIdsSince(
          DateTime.utc(1900),
        );
        final snapshot = LedgerSnapshot.project(
          events: affected,
          factsById: allFacts,
          instrumentsById: instruments,
          bundle: bundle,
          instrumentIdByFactId: instrumentIdByFactId,
          userRules: categories.userRules,
          confirmedHistory: categories.confirmedHistory,
          lockedCategories: ledger.categoryDecisions(),
        );
        final previous = {
          for (final event in affected)
            event.eventId: ledger.forEvent(event.eventId),
        };
        ProjectionWriter(financial, ledger).write(
          snapshot,
          factsById: allFacts,
          instrumentsById: instruments,
          instrumentIdByFactId: instrumentIdByFactId,
        );
        final queue = OutboxStore(db, namespace: namespace);
        queue.enqueue(
          'instrument',
          instrument.instrumentId,
          instrument.toJson(),
        );
        final keep = snapshot.entries.map((entry) => entry.entryId).toSet();
        for (final entries in previous.values) {
          for (final entry in entries) {
            if (!keep.contains(entry.entryId)) {
              db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
                namespace,
                'ledger:${entry.entryId}',
              ]);
            }
          }
        }
        for (final entry in snapshot.entries) {
          queue.enqueue('ledger', entry.entryId, entry.toJson());
        }
        for (final event in affected) {
          queue.enqueue('event', event.eventId, event.toJson());
        }
        db.execute('RELEASE SAVEPOINT sms_v2_instrument_choice');
        financial.notifyExternalChanges(namespace, const [
          'transactions',
          'observations',
        ]);
      } catch (_) {
        db.execute('ROLLBACK TO SAVEPOINT sms_v2_instrument_choice');
        db.execute('RELEASE SAVEPOINT sms_v2_instrument_choice');
        rethrow;
      }
    });
  }
}
