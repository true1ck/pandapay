/// Whole-person name matching for own-money detection.
///
/// A bank prints the account holder's name on both sides of a transfer, often
/// cut short ("CHANDRESH GOPAL" for "CHANDRESH GOPAL KERKAR") or with the
/// last name reduced to an initial ("CHANDRESH GOPAL K"). These helpers decide
/// whether two printed names describe one person. They are strict on purpose:
/// a shared first name alone is never a match.
library;

final _nonLetters = RegExp(r'[^A-Z]+');

/// The upper-case letter-only words of [raw], in order.
List<String> personNameTokens(String? raw) {
  if (raw == null) return const [];
  return raw
      .toUpperCase()
      .replaceAll(_nonLetters, ' ')
      .trim()
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList();
}

/// True when [a] and [b] are the same person's name, allowing a shortened
/// name, an initial in place of a word, or words run together
/// ("CHANDRESHGOPALK"). Needs two full words in common (or ten run-together
/// letters), so "CHANDRESH SHARMA" does not match "CHANDRESH KERKAR".
bool namesDescribeSamePerson(String? a, String? b) {
  final x = personNameTokens(a);
  final y = personNameTokens(b);
  if (x.isEmpty || y.isEmpty) return false;

  final gx = x.join();
  final gy = y.join();
  if (gx.length >= 10 &&
      gy.length >= 10 &&
      (gx == gy || gx.startsWith(gy) || gy.startsWith(gx))) {
    return true;
  }

  final small = x.length <= y.length ? x : y;
  final pool = [...(x.length <= y.length ? y : x)];
  if (small.length < 2) return false;
  var fullWords = 0;
  for (final word in small) {
    final i = pool.indexWhere(
      (p) => p == word || (word.length == 1 && p.startsWith(word)),
    );
    if (i < 0) return false;
    if (word.length > 1) fullWords++;
    pool.removeAt(i);
  }
  return fullWords >= 2;
}

/// True when [name] is the name of one of the account owner's [ownerNames].
///
/// For a three-word owner name the first-and-last form also counts
/// ("CHANDRESH KERKAR" for "CHANDRESH GOPAL KERKAR"). A one-word owner name
/// never matches, because a first name alone does not identify anyone.
bool nameIsOneOf(String? name, Iterable<String> ownerNames) {
  for (final owner in ownerNames) {
    final words = personNameTokens(owner);
    if (words.length < 2) continue;
    if (namesDescribeSamePerson(name, owner)) return true;
    if (words.length >= 3 &&
        namesDescribeSamePerson(name, '${words.first} ${words.last}')) {
      return true;
    }
  }
  return false;
}
