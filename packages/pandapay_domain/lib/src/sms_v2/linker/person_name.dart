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

/// How much a payee's name looks like the owner's family.
enum FamilyMatch { none, weak, strong }

// ponytail: short fixed lists. Move to pack params, or count words seen in many
// unrelated payees, when these miss real cases.
const _honorifics = {'SMT', 'SHRI', 'SHRIMATI', 'MR', 'MRS', 'MS', 'KUM'};
const _businessWords = {
  'STORES', 'STORE', 'HARDWARE', 'TRADERS', 'TRADING', 'ENTERPRISES', 'ENTERPRISE',
  'SHOP', 'MART', 'AGENCY', 'AGENCIES', 'SERVICES', 'PVT', 'LTD', 'LIMITED',
  'CO', 'BANK', 'MEDICAL', 'FOODS', 'RESTAURANT', 'HOTEL', 'SONS', 'BROTHERS',
};
const _commonWords = {
  'KUMAR', 'SINGH', 'DEVI', 'KAUR', 'KHAN', 'LAL', 'RAM', 'MOHD', 'MOHAMMED', 'SHARMA',
};

/// Whether [payee] looks like family of the owner (any of [ownerNames], in
/// reading order: first, father's name, then surname).
///
/// Strong: shares the surname (whole, cut to four letters or more, or as an
/// initial beside the father's name), with another word or an honorific beside
/// it. Weak: the father's name plus one more word, or a very common surname.
/// Never a first name alone, a business, or the owner themselves.
FamilyMatch familyLikeName(String? payee, Iterable<String> ownerNames) {
  final raw = personNameTokens(payee);
  final p = [for (final t in raw) if (!_honorifics.contains(t)) t];
  if (p.isEmpty || p.any(_businessWords.contains)) return FamilyMatch.none;
  final hadHonorific = p.length < raw.length;
  var best = FamilyMatch.none;
  for (final owner in ownerNames) {
    final o = [
      for (final t in personNameTokens(owner)) if (!_honorifics.contains(t)) t,
    ];
    if (o.length < 2 || namesDescribeSamePerson(payee, owner)) continue;
    final last = o.last;
    final fathers = o.length >= 3 ? o.sublist(1, o.length - 1) : const <String>[];
    final hasFather = p.any(fathers.contains);
    final surname = p.asMap().entries.any((e) {
      final t = e.value;
      if (t == last || (t.length >= 4 && last.startsWith(t))) return true;
      return t.length == 1 && e.key > 0 && last.startsWith(t) && hasFather;
    });
    var m = FamilyMatch.none;
    if (surname && (p.length >= 2 || hadHonorific)) {
      m = _commonWords.contains(last) ? FamilyMatch.weak : FamilyMatch.strong;
    } else if (hasFather && p.length >= 2) {
      m = FamilyMatch.weak;
    }
    if (m.index > best.index) best = m;
  }
  return best;
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
