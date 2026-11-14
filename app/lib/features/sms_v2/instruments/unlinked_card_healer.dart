import 'package:pandapay_domain/sms_v2.dart'
    show Instrument, InstrumentKind, InstrumentStatus;

import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart' show TxnInstrument;
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';

/// Where a walk over unlinked movements stopped: the last fact it read.
typedef HealCursor = ({DateTime at, String factId});

/// Links card movements that were saved with no card record (none fitted when
/// the message was read, or several did) to the wallet card they name, and
/// shows that card on their saved transactions.
///
/// Without it such a row says "Payment method not matched" for good: later
/// linking (a card added, "Found cards" confirmed) only reaches rows whose fact
/// already has a card.
///
/// Cheap by construction (R1, R4, R5): [step] reads at most [chunkSize] (50) facts
/// through the observed-time index, links the ones with exactly one matching
/// wallet card, and writes the card onto their rows through
/// `financial_source_identity`. No re-projection and no read of the whole
/// history. The caller yields between steps.
class UnlinkedCardHealer {
  UnlinkedCardHealer(this.financial, {required this.namespace});

  final FinancialStore financial;
  final String namespace;

  static const chunkSize = 50;

  /// One bounded step. [next] is where to continue, or null when the walk is
  /// finished. Facts that fit no wallet card stay unlinked and are passed over
  /// by the cursor, so a walk always ends.
  ({int linked, HealCursor? next}) step({
    HealCursor? after,
    DateTime? now,
    int days = 400,
    int limit = chunkSize,
  }) {
    final db = financial.database.db;
    final wallet = [
      for (final i in InstrumentStore(db, namespace: namespace).list())
        if (i.userCardId != null &&
            i.status != InstrumentStatus.rejected &&
            i.maskDigits != null &&
            (i.kind == InstrumentKind.creditCard ||
                i.kind == InstrumentKind.debitCard))
          i,
    ];
    if (wallet.isEmpty) return (linked: 0, next: null);
    final from = (now ?? DateTime.now()).toUtc().subtract(Duration(days: days));
    final facts = FactStore(db, namespace: namespace);
    final read = facts.unlinkedMovementsSince(from, limit: limit, after: after);
    if (read.isEmpty) return (linked: 0, next: null);
    final next = read.length < limit
        ? null
        : (at: read.last.observedAt, factId: read.last.factId);

    final byCard = <String, ({Instrument card, List<String> facts, Set<String> sources})>{};
    for (final fact in read) {
      final said = fact.instrument;
      final mask = said?.maskDigits;
      if (said == null ||
          said.issuerSlug == null ||
          mask == null ||
          (said.kind != null &&
              said.kind != InstrumentKind.creditCard &&
              said.kind != InstrumentKind.debitCard)) {
        continue;
      }
      final fits = [
        for (final card in wallet)
          if (card.issuerSlug == said.issuerSlug &&
              (said.kind == null || card.kind == said.kind) &&
              _sameNumber(card.maskDigits!, mask))
            card,
      ];
      if (fits.length != 1) continue; // never a guess between two cards
      final entry = byCard.putIfAbsent(
        fits.single.instrumentId,
        () => (card: fits.single, facts: <String>[], sources: <String>{}),
      );
      entry.facts.add(fact.factId);
      entry.sources.add(fact.sourceKey);
    }
    var linked = 0;
    if (byCard.isNotEmpty) {
      // The link and the rows change together: a failure leaves both as they
      // were, and the next walk finds the same facts again.
      financial.batch(() {
        for (final entry in byCard.values) {
          for (final id in entry.facts) {
            facts.linkInstrument(id, entry.card.instrumentId);
          }
          financial.stampUnmatchedCardOnSmsTransactions(
            namespace,
            entry.sources,
            userCardId: entry.card.userCardId!,
            instrument: entry.card.kind == InstrumentKind.debitCard
                ? TxnInstrument.debitCard
                : TxnInstrument.creditCard,
            cardLast4: _last4(entry.card.maskDigits),
            cardName: entry.card.displayName,
          );
          linked += entry.facts.length;
        }
      });
    }
    return (linked: linked, next: next);
  }

  /// The whole walk in one go, for callers that are not on the UI thread
  /// (tests). The app walks it a step at a time, yielding between steps.
  int healAll({DateTime? now, int days = 400}) {
    var total = 0;
    HealCursor? cursor;
    do {
      final r = step(after: cursor, now: now, days: days);
      total += r.linked;
      cursor = r.next;
    } while (cursor != null);
    return total;
  }

  static bool _sameNumber(String a, String b) =>
      a == b ||
      (a.length >= 4 && b.length >= 4 && (a.endsWith(b) || b.endsWith(a)));

  /// The digits a transaction shows: the last 4 of the number, or all of a
  /// shorter one. Mirrors `transactionForEvent`.
  static String? _last4(String? mask) => mask == null
      ? null
      : mask.length > 4
      ? mask.substring(mask.length - 4)
      : mask;
}
