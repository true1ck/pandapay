import '../contract/enums.dart';
import '../contract/event.dart';
import '../linker/owner_identity.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';

/// Whether a card-payment notice may CREATE a card the user has not been seen
/// with.
///
/// Issuers print a card by more than one number: the card number on spend
/// alerts and statements, the card ACCOUNT number on payment receipts, a new
/// number after a reissue. A payment receipt proves that a payment happened; it
/// does not prove that a new card exists. When the issuer already has a card,
/// a number first seen on a payment receipt is far more likely to be another
/// name for one of them than a new card, and creating it would show a phantom
/// card with payments and no spend.
///
/// So a payment notice never creates a second card for an issuer that already
/// has one. The payment stays on "card not identified"; a spend alert or a
/// statement that names the number creates the card, and the earlier payment
/// finds it by number when the ledger is built. Everything else may create:
/// a spend alert, a statement, the first card of an issuer, a wallet or an
/// account.
///
/// It reads only the instruments known when the notice arrives, so it needs no
/// look-back and no merge of stored instruments.
bool cardPaymentMayCreateCard(Fact fact, Iterable<Instrument> known) {
  if (fact is! MovementFact) return true;
  final mention = fact.instrument;
  if (mention == null ||
      mention.kind != InstrumentKind.creditCard ||
      mention.issuerSlug == null ||
      fact.direction != Direction.credit ||
      fact.purpose != MovementPurpose.cardPayment) {
    return true;
  }
  return !known.any(
    (i) =>
        i.kind == InstrumentKind.creditCard &&
        i.issuerSlug == mention.issuerSlug &&
        i.status != InstrumentStatus.rejected,
  );
}

/// Detected bank accounts that look like someone else's: money moved on them,
/// none of their messages names the owner (as a payer or payee), and none of
/// their money moved to or from another of the owner's accounts. A hint for the
/// "Not mine" button only; nothing is rejected or hidden because of it. With no
/// owner name known there is nothing to compare, so nothing is suggested.
Set<String> notMineSuggestions({
  required Iterable<Instrument> instruments,
  required Iterable<Fact> facts,
  required Map<String, String> instrumentIdByFactId,
  required Iterable<Event> events,
  required OwnerIdentity identity,
}) {
  if (identity.names.isEmpty) return const {};
  final seen = <String>{};
  final named = <String>{};
  for (final f in facts) {
    final id = instrumentIdByFactId[f.factId];
    if (id == null || f is! MovementFact) continue;
    seen.add(id);
    final cp = f.counterparty;
    if (cp != null &&
        (cp.kind == CounterpartyKind.own || identity.matchesName(cp.name))) {
      named.add(id);
    }
  }
  final transfers = <String>{
    for (final e in events)
      if (e.type == EventType.ownTransfer)
        for (final l in e.legs)
          ?instrumentIdByFactId[l.factId],
  };
  return {
    for (final i in instruments)
      if (i.kind == InstrumentKind.bankAccount &&
          i.status == InstrumentStatus.detected &&
          seen.contains(i.instrumentId) &&
          !named.contains(i.instrumentId) &&
          !transfers.contains(i.instrumentId))
        i.instrumentId,
  };
}
