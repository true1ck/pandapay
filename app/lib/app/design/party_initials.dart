import '../../data/merchant_identity.dart';

/// The one or two letters that stand for a person or a business on its tile
/// when there is no brand logo: "Rahul Kumar Sharma" is RS, "Avighna
/// Enterprise" is AE, "Ownly" is O.
///
/// Returns an empty string when the name says nothing about who it is (a
/// missing name, "Unknown merchant", a bare number, a UPI handle), so the tile
/// keeps its icon instead of showing a meaningless letter.
class PartyInitials {
  const PartyInitials._();

  // Combining marks (vowel signs in Devanagari, accents) stay inside a word.
  static final _separatorRe = RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true);
  static final _letterOrDigitRe = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Labels the app writes in place of a name: "Unknown sender", and a
  /// "Transfer to" with nobody after it.
  static final _saysNothingRe = RegExp(
    r'^\s*(?:unknown\s+sender|transfer\s+to)\s*$',
    caseSensitive: false,
  );

  /// Words that say what kind of entity a name is, not which one.
  static const _skippedWords = {
    'mr', 'mrs', 'ms', 'miss', 'shri', 'smt', 'sri', 'dr', //
    'pvt', 'private', 'ltd', 'limited', 'llp', 'inc', 'corp', 'co',
    'the', 'and', 'of',
  };

  /// A person is first name plus last name; a business is its first two words.
  static String of(String? name, {bool person = false}) {
    if (name == null) return '';
    final payee = MerchantIdentity.transferPayee(name) ?? name;
    if (MerchantIdentity.isWeakName(payee) || _saysNothingRe.hasMatch(payee)) {
      return '';
    }

    final words = payee
        .split(_separatorRe)
        .where((w) => w.isNotEmpty && _letterOrDigitRe.hasMatch(w))
        .toList();
    final named = words
        .where((w) => !_skippedWords.contains(w.toLowerCase()))
        .toList();
    final use = named.isEmpty ? words : named;
    if (use.isEmpty) return '';

    final first = _first(use.first);
    if (use.length == 1) return first;
    final second = _first(person ? use.last : use[1]);
    return '$first$second';
  }

  /// The first letter or digit of [word], upper-cased. The base letter only:
  /// a Devanagari "दी" is द, not the letter with its vowel sign.
  static String _first(String word) {
    for (final rune in word.runes) {
      final char = String.fromCharCode(rune);
      if (_letterOrDigitRe.hasMatch(char)) return char.toUpperCase();
    }
    return '';
  }
}
