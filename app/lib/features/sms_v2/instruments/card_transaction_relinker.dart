import 'package:pandapay_domain/sms_v2.dart' show Instrument, InstrumentKind;
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/financial_store.dart';
import '../storage/instrument_store.dart';
import '../storage/sync_state_store.dart';

/// Gives the transactions that were saved BEFORE a card was linked to its
/// wallet card that card.
///
/// A saved SMS transaction copies the wallet card id from the card the
/// messages found at the moment it was saved. When the wallet card was added
/// afterwards (or the link was made on "Accounts and cards we found"), those
/// rows kept no card, so the Activity card filter, the card page, caps and
/// rewards all missed them. The instrument link alone changes no ledger row;
/// this is the missing second half.
///
/// Cost is bounded by the card's own transactions (R1, R4, R5): its source
/// keys come from the `idx_v2_facts_instrument` index, then each is looked up
/// through `financial_source_identity` in chunks, and only rows that need the
/// change are decoded. Nothing here reads the whole history.
class CardTransactionRelinker {
  CardTransactionRelinker(this.financial, {required this.namespace});

  final FinancialStore financial;
  final String namespace;

  /// The source keys of the messages that named an instrument.
  static const factKeysSql =
      'SELECT DISTINCT source_key FROM v2_facts '
      'WHERE namespace = ? AND instrument_id = ?';

  static const _doneMarker = 'card-relink:1';

  Database get _db => financial.database.db;

  bool get _ready {
    final names = _db
        .select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name IN ('v2_facts','v2_instruments','v2_sync_state')",
        )
        .length;
    return names == 3;
  }

  /// Stamps [instrument]'s wallet card on its saved transactions. Returns how
  /// many rows changed; 0 for a card with no wallet card, any other kind of
  /// instrument, or rows that already carry it.
  int relink(Instrument instrument) {
    final cardId = instrument.userCardId;
    final isCard =
        instrument.kind == InstrumentKind.creditCard ||
        instrument.kind == InstrumentKind.debitCard;
    if (cardId == null || !isCard || !_ready) return 0;
    final keys = [
      for (final row in _db.select(factKeysSql, [
        namespace,
        instrument.instrumentId,
      ]))
        row['source_key'] as String,
    ];
    return financial.stampCardOnSmsTransactions(
      namespace,
      keys,
      userCardId: cardId,
      cardLast4: _last4(instrument.maskDigits),
    );
  }

  int relinkAll(Iterable<Instrument> instruments) {
    var changed = 0;
    for (final instrument in instruments) {
      changed += relink(instrument);
    }
    return changed;
  }

  /// For a wallet card whose id changed (the server answered with another id
  /// than the phone's): the instrument already follows it, so its rows do too.
  int relinkCard(String userCardId) {
    if (!_ready) return 0;
    final instrument = InstrumentStore(
      _db,
      namespace: namespace,
    ).findByUserCardId(userCardId);
    return instrument == null ? 0 : relink(instrument);
  }

  /// One pass over every card already linked to a wallet card, for phones that
  /// linked cards before this existed. Runs once per account (a marker in the
  /// sync state), so later calls cost one lookup.
  int repairOnce() {
    if (!_ready) return 0;
    final state = SyncStateStore(_db, namespace: namespace);
    if (state.get(_doneMarker) != null) return 0;
    final changed = relinkAll([
      for (final i in InstrumentStore(_db, namespace: namespace).list())
        if (i.userCardId != null) i,
    ]);
    state.put(_doneMarker, DateTime.now().toUtc().toIso8601String());
    return changed;
  }

  /// The digits a transaction shows for a card: the last 4 of the number, or
  /// all of a shorter one. Mirrors `transactionForEvent`.
  static String? _last4(String? mask) => mask == null
      ? null
      : mask.length > 4
      ? mask.substring(mask.length - 4)
      : mask;
}
