import 'package:pandapay_domain/sms_v2.dart'
    show Instrument, InstrumentKind, InstrumentStatus;

import '../../../data/user_cards_repository.dart' show UserCard;

final RegExp _maskPattern = RegExp(r'^\d{2,6}$');

/// The instrument kind a wallet card stands for.
InstrumentKind cardKindOf(UserCard card) => switch (card.cardType) {
  'debit' => InstrumentKind.debitCard,
  'prepaid' => InstrumentKind.prepaidCard,
  _ => InstrumentKind.creditCard,
};

/// The wallet card's last digits when they look like a card number ending.
String? cardMaskOf(UserCard card) {
  final last4 = card.last4;
  return last4 != null && _maskPattern.hasMatch(last4) ? last4 : null;
}

/// Pairs a wallet card with the card the messages found when exactly one side
/// is missing the number, which exact matching on last 4 digits cannot do.
///
/// Two cases cause it. A card is added to the wallet without its last 4 digits
/// (Find cards and Scan do not ask for them), while the messages found it as
/// "HDFC ending 5678". Or the messages never printed a number, and the wallet
/// card has one. Without pairing, each becomes its own card: the transactions
/// stay on the found one, which has no wallet card, and the wallet card shows
/// none.
///
/// It only ever pairs when there is no choice to make: one candidate for the
/// card, and no other wallet card that could equally be that candidate. A
/// second HDFC card in either list turns it into a guess, and a guess is never
/// made (the user confirms it on "Accounts and cards we found").
class CardPairing {
  CardPairing({
    required Iterable<Instrument> instruments,
    required Iterable<UserCard> wallet,
    required this.issuerSlugOf,
  }) : _instruments = instruments.toList(),
       _wallet = [
         for (final c in wallet)
           if (!c.isArchived) c,
       ],
       _linkedCardIds = {
         for (final i in instruments)
           if (i.userCardId != null) i.userCardId!,
       };

  /// A wallet card's issuer slug (see `cardIssuerSlugFromCatalogue`).
  final String? Function(UserCard) issuerSlugOf;
  final List<Instrument> _instruments;
  final List<UserCard> _wallet;
  final Set<String> _linkedCardIds;

  /// The one found card that [card] can only be, or null.
  Instrument? instrumentForCard(UserCard card) {
    if (_linkedCardIds.contains(card.id)) return null;
    final candidates = [
      for (final i in _instruments)
        if (_compatible(card, i)) i,
    ];
    if (candidates.length != 1) return null;
    final only = candidates.single;
    final rivals = _wallet.where(
      (w) =>
          w.id != card.id &&
          !_linkedCardIds.contains(w.id) &&
          _compatible(w, only),
    );
    return rivals.isEmpty ? only : null;
  }

  /// The one wallet card that [instrument] can only be, or null.
  UserCard? cardForInstrument(Instrument instrument) {
    final candidates = [
      for (final w in _wallet)
        if (!_linkedCardIds.contains(w.id) && _compatible(w, instrument)) w,
    ];
    if (candidates.length != 1) return null;
    final only = candidates.single;
    return instrumentForCard(only)?.instrumentId == instrument.instrumentId
        ? only
        : null;
  }

  bool _compatible(UserCard card, Instrument i) {
    if (i.userCardId != null ||
        i.status == InstrumentStatus.rejected ||
        i.status == InstrumentStatus.archived ||
        i.kind != cardKindOf(card) ||
        i.issuerSlug != issuerSlugOf(card)) {
      return false;
    }
    // Two numbers are compared by exact key elsewhere; pairing is only for a
    // side with no number.
    if (cardMaskOf(card) != null && i.maskDigits != null) return false;
    // A found card whose number is another wallet card's last 4 belongs to that
    // card (the exact match takes it), never to a card with no number.
    final mask = i.maskDigits;
    if (mask != null &&
        _wallet.any(
          (w) =>
              w.id != card.id &&
              cardKindOf(w) == i.kind &&
              issuerSlugOf(w) == i.issuerSlug &&
              cardMaskOf(w) == mask,
        )) {
      return false;
    }
    return _productsCompatible(i.aliases.productNames, card.cardName);
  }

  /// Same test the message resolver uses between a found card and a product
  /// name: nothing known on either side is compatible; otherwise one name
  /// contains the other.
  static bool _productsCompatible(List<String> known, String name) {
    final b = name.trim().toLowerCase();
    if (b.isEmpty || known.isEmpty) return true;
    return known.any((a) {
      final x = a.trim().toLowerCase();
      return x.isEmpty || x.contains(b) || b.contains(x);
    });
  }
}
