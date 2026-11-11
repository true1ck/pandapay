import '../category/merchant_key.dart';
import '../contract/enums.dart';
import '../contract/event.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/types.dart';
import '../instruments/instrument_resolver.dart' show defaultIssuerLabel;

/// Where a counterparty came from when the money message did not print one.
enum CounterpartyOrigin {
  /// Another leg of the same event names it: the purchase a refund reverses, the
  /// bank's record that a payer's notice confirms.
  linked,

  /// The instrument's own issuer: a wallet's own cashback, refund or payment, a
  /// bank's own fee.
  issuer,
}

final class ResolvedCounterparty {
  const ResolvedCounterparty(this.counterparty, this.origin);
  final Counterparty counterparty;
  final CounterpartyOrigin origin;
}

/// Whether [c] names someone: a name or a UPI id, and not one of the person's
/// own accounts.
bool counterpartyIsNamed(Counterparty? c) {
  if (c == null || c.kind == CounterpartyKind.own) return false;
  return normalizeMerchantText(c.name ?? '').isNotEmpty ||
      normalizeMerchantText(c.vpa ?? '').isNotEmpty;
}

/// Who a movement was with, when its own message names nobody.
///
/// A message that prints no merchant or sender still sits in a story the
/// phone knows. This answers in a fixed order, and stops at the first that
/// holds:
///
/// 1. **The printed name** (not this function's job: call it only when
///    [counterpartyIsNamed] is false for the money fact).
/// 2. **A linked leg's name.** A refund or reversal is with the same merchant as
///    the purchase it reverses; a payer's notice is with whoever the bank's own
///    record of the same credit names. Legs are read in the order original,
///    duplicate notice, then any other; the first that names someone wins.
/// 3. **The issuer, only where the issuer necessarily is the other side.** A
///    wallet's own cashback, refund, balance expiry credit or payment is with
///    the wallet's provider; a fee on an account or card is charged by its
///    bank. Never for a credit into a bank account (the bank is not the
///    sender), never for a purchase on a card or account (the card issuer is not
///    the merchant), never for an own transfer, a card bill payment or a wallet
///    top-up (those have their own labels).
/// 4. **Nobody**: null. The screen then says "Unknown merchant" or "Unknown
///    sender".
///
/// A name printed on the money message always beats a linked or issuer name, and
/// this function never replaces one.
ResolvedCounterparty? resolveMissingCounterparty({
  required Event event,
  required MovementFact money,
  required Map<String, Fact> factsById,
  Instrument? instrument,
  String Function(String issuerSlug)? issuerLabel,
}) {
  // 2. a linked leg that names someone
  const order = [LegRole.original, LegRole.duplicateNotice];
  final legs = [
    for (final role in order)
      for (final l in event.legs)
        if (l.role == role) l,
    for (final l in event.legs)
      if (!order.contains(l.role)) l,
  ];
  for (final leg in legs) {
    final fact = factsById[leg.factId];
    if (fact == null || fact.factId == money.factId) continue;
    if (counterpartyIsNamed(fact.counterparty)) {
      return ResolvedCounterparty(fact.counterparty!, CounterpartyOrigin.linked);
    }
  }

  // 3. the issuer, where it necessarily is the other side
  if (instrument == null) return null;
  final issuer = instrument.issuerSlug;
  if (issuer.isEmpty) return null;
  final label = (issuerLabel ?? defaultIssuerLabel)(issuer);
  switch (event.type) {
    case EventType.ownTransfer:
    case EventType.cardBillPayment:
    case EventType.walletTopup:
      return null;
    default:
      break;
  }
  if (instrument.kind == InstrumentKind.wallet) {
    return ResolvedCounterparty(
      Counterparty(name: label, kind: CounterpartyKind.merchant),
      CounterpartyOrigin.issuer,
    );
  }
  if (event.type == EventType.fee &&
      (instrument.kind == InstrumentKind.bankAccount ||
          instrument.kind == InstrumentKind.creditCard ||
          instrument.kind == InstrumentKind.debitCard ||
          instrument.kind == InstrumentKind.prepaidCard)) {
    return ResolvedCounterparty(
      Counterparty(name: '$label Bank', kind: CounterpartyKind.bank),
      CounterpartyOrigin.issuer,
    );
  }
  return null;
}
