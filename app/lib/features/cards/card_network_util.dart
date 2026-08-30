import 'package:pandapay_domain/pandapay_domain.dart';

/// Human label for a card network. Shared by the catalogue picker's filter
/// chips and the "which network is yours?" chooser on the discovery screen
/// so the two never drift apart.
String cardNetworkLabel(CardNetwork n) => switch (n) {
  CardNetwork.rupay => 'RuPay',
  CardNetwork.visa => 'Visa',
  CardNetwork.mastercard => 'Mastercard',
  CardNetwork.amex => 'Amex',
  CardNetwork.diners => 'Diners',
  CardNetwork.unknown => 'Other',
};

const _networkWordsInName = [
  'mastercard',
  'master card',
  'american express',
  'diners club',
  'rupay',
  'visa',
  'amex',
  'diners',
];

/// The card's name with any network word stripped, lower-cased and
/// whitespace-collapsed — the key that groups "ICICI Coral RuPay" and
/// "ICICI Coral" (a Visa row) as the same physical card.
String networkAgnosticCardName(String name) {
  var n = name.toLowerCase();
  for (final w in _networkWordsInName) {
    n = n.replaceAll(w, ' ');
  }
  return n.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Catalogue rows that are the same physical card as [card] but may sit on a
/// different network — same issuer, same network-agnostic name. Always
/// includes [card] itself. A single-element result means there is nothing to
/// choose and the caller should keep its plain confirm button.
List<CardProduct> networkVariantsOf(CardProduct card, List<CardProduct> catalogue) {
  final issuer = card.issuerName;
  final base = networkAgnosticCardName(card.name);
  if (issuer == null || issuer.isEmpty || base.isEmpty) return [card];
  final variants = catalogue
      .where((c) =>
          c.issuerName == issuer && networkAgnosticCardName(c.name) == base)
      .toList()
    ..sort((a, b) => a.network.index.compareTo(b.network.index));
  return variants.isEmpty ? [card] : variants;
}
