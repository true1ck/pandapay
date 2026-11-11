import '../contract/enums.dart';
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
