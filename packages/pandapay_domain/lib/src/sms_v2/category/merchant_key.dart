import '../contract/enums.dart';
import '../contract/rule_bundle.dart';
import '../contract/types.dart';

final RegExp _separators = RegExp(r'[^A-Z0-9&]+');
final RegExp _spaces = RegExp(r' {2,}');
final RegExp _longDigits = RegExp(r'\d{4,}');
final RegExp _onlyDigits = RegExp(r'^[0-9]+$');
final RegExp _onlyDigitsAndSpaces = RegExp(r'^[0-9 ]+$');

/// Upper-cases [raw] and reduces it to tokens of `A-Z`, `0-9` and `&`,
/// separated by single spaces. `MCDONALD'S` becomes `MCDONALD S`,
/// `APPLE.COM/BILL` becomes `APPLE COM BILL`. Rule keys and alias keys go
/// through the same function, so both sides always agree.
String normalizeMerchantText(String raw) =>
    raw.toUpperCase().replaceAll(_separators, ' ').trim().replaceAll(_spaces, ' ');

/// The space-separated tokens of a normalised key.
List<String> merchantTokens(String normalizedKey) =>
    normalizedKey.isEmpty ? const [] : normalizedKey.split(' ');

const Set<String> _legalSuffixes = {'LTD', 'LIMITED', 'LLP', 'INC', 'LLC', 'PLC'};
const Set<String> _legalQualifiers = {'PVT', 'PRIVATE'};

/// UPI handle fragments that carry no merchant name.
const Set<String> _vpaNoise = {
  'RZP',
  'RAZORPAY',
  'PAYU',
  'BILLDESK',
  'CCAVENUE',
  'QR',
  'UPI',
  'PAYTMQR',
  'PAYMENT',
  'PAYMENTS',
};

/// Strips trailing legal suffixes (`PVT LTD`, `PRIVATE LIMITED`, `LLP`, ...).
/// Never strips the last remaining token.
String stripLegalSuffix(String normalizedKey) {
  final tokens = merchantTokens(normalizedKey).toList();
  var strippedSuffix = false;
  while (tokens.length > 1) {
    final last = tokens.last;
    if (_legalSuffixes.contains(last)) {
      strippedSuffix = true;
    } else if (_legalQualifiers.contains(last) || (last == 'P' && strippedSuffix)) {
      // `PVT` / `PRIVATE`, or the `(P)` of `(P) LTD`.
    } else {
      break;
    }
    tokens.removeLast();
  }
  return tokens.join(' ');
}

/// Turns a counterparty into the key the category rules match on.
///
/// - upper case, legal suffixes stripped
/// - the bundle's `merchantAliases` map a whole key to a canonical key
///   (`AMAZON PAY IN` to `AMAZON`)
/// - a UPI ID is looked up in the alias table first, then its readable local
///   part is used
/// - a person never gets a key (see [keyFor])
class MerchantKeyer {
  MerchantKeyer([Iterable<MerchantAlias> aliases = const []])
      : _aliases = {
          for (final a in aliases)
            if (normalizeMerchantText(a.alias).isNotEmpty && normalizeMerchantText(a.merchantKey).isNotEmpty)
              normalizeMerchantText(a.alias): normalizeMerchantText(a.merchantKey),
        };

  final Map<String, String> _aliases;

  /// Number of alias entries in use.
  int get aliasCount => _aliases.length;

  /// The key for a counterparty, or null when it has none: no counterparty, a
  /// person, one of the user's own accounts, or a name and UPI ID with nothing
  /// readable in them.
  String? keyFor(Counterparty? counterparty) {
    if (counterparty == null) return null;
    if (counterparty.kind == CounterpartyKind.person || counterparty.kind == CounterpartyKind.own) {
      return null;
    }
    final name = counterparty.name;
    if (name != null && name.trim().isNotEmpty) {
      final key = name.contains('@') && counterparty.vpa == null ? keyForVpa(name) : keyForName(name);
      if (key != null) return key;
    }
    final vpa = counterparty.vpa;
    if (vpa != null && vpa.trim().isNotEmpty) return keyForVpa(vpa);
    return null;
  }

  /// The key used to look up a user rule for a person's payment (`p2p_out`).
  /// It is the UPI ID when there is one, otherwise the name. It is never used
  /// for bundle rules, history or aliases, so a person never becomes a
  /// merchant key.
  String? personRuleKey(Counterparty? counterparty) {
    if (counterparty == null) return null;
    for (final raw in [counterparty.vpa, counterparty.name]) {
      if (raw == null) continue;
      final k = normalizeMerchantText(raw);
      if (k.isNotEmpty) return k;
    }
    return null;
  }

  /// The key for a merchant name, or null for an empty or all-digit name.
  String? keyForName(String raw) {
    final n = normalizeMerchantText(raw);
    if (n.isEmpty || _onlyDigitsAndSpaces.hasMatch(n)) return null;
    final direct = _aliases[n];
    if (direct != null) return direct;
    final stripped = stripLegalSuffix(n);
    return _aliases[stripped] ?? stripped;
  }

  /// The key for a UPI ID (`swiggy@icici`), or null when the local part is a
  /// number or has nothing readable.
  String? keyForVpa(String vpa) {
    final at = vpa.indexOf('@');
    final local = at < 0 ? vpa : vpa.substring(0, at);
    final full = _aliases[normalizeMerchantText(vpa)];
    if (full != null) return full;
    final localKey = normalizeMerchantText(local);
    final viaAlias = _aliases[localKey];
    if (viaAlias != null) return viaAlias;
    final readable = [
      for (final t in merchantTokens(localKey))
        if (!_longDigits.hasMatch(t) && !_vpaNoise.contains(t)) t,
    ];
    if (readable.isEmpty || readable.every(_onlyDigits.hasMatch)) return null;
    final joined = readable.take(5).join(' ');
    return _aliases[joined] ?? stripLegalSuffix(joined);
  }
}

/// A one-off key without building a [MerchantKeyer].
String? merchantKey(Counterparty? counterparty, {Iterable<MerchantAlias> aliases = const []}) =>
    MerchantKeyer(aliases).keyFor(counterparty);
