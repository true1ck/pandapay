/// Who counts as "the account owner" when a payment names its other side.
///
/// A bank prints the holder's name on both sides of a transfer between a
/// person's own accounts, in whatever shape its screen allows: the full name,
/// a name cut short ("ISHAAN DATTATRAY RANG"), a middle name reduced to an
/// initial, honorifics ("MR ISHAAN RANGNEKAR"), the surname first, or a UPI
/// handle built from the name ("ishaanrangnekar-2@bank"). This file decides
/// whether a printed name or handle belongs to the owner.
///
/// The rules are strict on purpose, because a wrong "yes" hides real spending:
///
/// * The owner's FIRST name must match in full. A middle name is usually the
///   father's name and a surname is shared by the whole family, so siblings
///   ("KABIR DATTATRAY RANGNEKAR" for "ISHAAN DATTATRAY RANGNEKAR") match on
///   everything except the first name and must be refused.
/// * One more full word (middle or last name) must match, or the last name
///   must appear cut short by the bank (three letters or more).
/// * Every word printed must be explained by the owner's name. An extra full
///   word ("ISHAAN RANGNEKAR PATIL") means a different person.
/// * A first name alone, an initial alone, or a surname alone never matches.
///
/// Nothing here knows a bank, a person or a language: it works on the owner's
/// own words. Where the owner has no usable name the identity is empty and
/// nothing is claimed.
library;

import 'owner_vocabulary.dart';
import 'person_name.dart';

final _notLowerLetter = RegExp(r'[^a-z]');
final _digits4 = RegExp(r'^\d{4,}$');

List<String> _words(String? raw) {
  final honorifics = OwnerVocabulary.current.honorifics;
  return [
    for (final w in personNameTokens(raw))
      if (!honorifics.contains(w)) w,
  ];
}

/// One person's name as first, optional middle words, and last.
///
/// Built from a name in reading order ("Ishaan Dattatray Rangnekar") or from
/// separate parts the person typed.
class OwnerName {
  const OwnerName._(this.first, this.middles, this.last);

  final String first;
  final List<String> middles;
  final String last;

  /// The name as a person writes it: first word first, last word last. Needs at
  /// least two words of two letters or more; anything less is not enough to
  /// tell this person from anyone else, so null is returned.
  static OwnerName? parse(String? raw) {
    final w = _words(raw);
    if (w.length < 2) return null;
    return fromParts(
      first: w.first,
      middle: w.length > 2 ? w.sublist(1, w.length - 1).join(' ') : null,
      last: w.last,
    );
  }

  /// A first name, an optional middle name and a last name typed separately.
  static OwnerName? fromParts({
    required String first,
    String? middle,
    required String last,
  }) {
    final f = _words(first).join();
    final l = _words(last).join();
    if (f.length < 2 || l.length < 2) return null;
    return OwnerName._(f, _words(middle), l);
  }

  /// Every word of the name.
  List<String> get words => [first, ...middles, last];

  /// The name run together in the orders a handle or a clipped print uses.
  Set<String> get runTogether {
    final mid = middles.join();
    return {first + last, last + first, first + mid + last, last + first + mid};
  }

  @override
  bool operator ==(Object other) =>
      other is OwnerName && other.words.join(' ') == words.join(' ');

  @override
  int get hashCode => words.join(' ').hashCode;

  @override
  String toString() => words.join(' ');
}

/// What the owner told us (or the app learned) about which names, handles and
/// payees are theirs.
class OwnerIdentity {
  OwnerIdentity({
    Iterable<OwnerName> names = const [],
    Iterable<String> vpas = const [],
    Iterable<String> payeeNames = const [],
    Iterable<String> accountMasks = const [],
    Iterable<String> notNames = const [],
    Iterable<String> notVpas = const [],
    Iterable<String> notMasks = const [],
    Iterable<String> familyNames = const [],
    Iterable<String> familyVpas = const [],
    Iterable<String> familyMasks = const [],
    Iterable<String> onceSelf = const [],
    Iterable<String> onceFamily = const [],
  }) : notNames = Set.unmodifiable({
         for (final n in notNames)
           if (_words(n).isNotEmpty) _words(n).join(' '),
       }),
       notVpas = Set.unmodifiable({for (final v in notVpas) v.trim().toLowerCase()}),
       notMasks = Set.unmodifiable({for (final m in notMasks) m.trim()}),
       names = List.unmodifiable({...names}),
       vpas = Set.unmodifiable({for (final v in vpas) v.trim().toLowerCase()}),
       payeeNames = Set.unmodifiable({
         for (final n in payeeNames)
           if (_words(n).length >= 2) _words(n).join(' '),
       }),
       accountMasks = Set.unmodifiable({
         for (final m in accountMasks)
           if (_digits4.hasMatch(m.trim())) m.trim(),
       }),
       familyNames = Set.unmodifiable({
         for (final n in familyNames)
           if (_words(n).length >= 2) _words(n).join(' '),
       }),
       familyVpas = Set.unmodifiable({
         for (final v in familyVpas)
           if (v.contains('@')) v.trim().toLowerCase(),
       }),
       familyMasks = Set.unmodifiable({
         for (final m in familyMasks)
           if (_digits4.hasMatch(m.trim())) m.trim(),
       }),
       onceSelf = Set.unmodifiable({for (final k in onceSelf) k.trim()}),
       onceFamily = Set.unmodifiable({for (final k in onceFamily) k.trim()});

  /// Built from the plain strings the capture path carries across isolates.
  ///
  /// A plain string is a name in reading order. `vpa:`, `payee:` and `mask:`
  /// prefixes carry the other kinds. A name with fewer than two words is
  /// dropped.
  factory OwnerIdentity.fromEntries(Iterable<String> entries) {
    final names = <OwnerName>[];
    final vpas = <String>[];
    final payees = <String>[];
    final masks = <String>[];
    final notNames = <String>[];
    final notVpas = <String>[];
    final notMasks = <String>[];
    final familyNames = <String>[];
    final familyVpas = <String>[];
    final familyMasks = <String>[];
    final onceSelf = <String>[];
    final onceFamily = <String>[];
    for (final raw in entries) {
      final e = raw.trim();
      if (e.startsWith(familyPayeePrefix)) {
        familyNames.add(e.substring(familyPayeePrefix.length));
      } else if (e.startsWith(familyVpaPrefix)) {
        familyVpas.add(e.substring(familyVpaPrefix.length));
      } else if (e.startsWith(familyMaskPrefix)) {
        familyMasks.add(e.substring(familyMaskPrefix.length));
      } else if (e.startsWith(onceSelfPrefix)) {
        onceSelf.add(e.substring(onceSelfPrefix.length));
      } else if (e.startsWith(onceFamilyPrefix)) {
        onceFamily.add(e.substring(onceFamilyPrefix.length));
      } else if (e.startsWith(notNamePrefix)) {
        notNames.add(e.substring(notNamePrefix.length));
      } else if (e.startsWith(notVpaPrefix)) {
        notVpas.add(e.substring(notVpaPrefix.length));
      } else if (e.startsWith(notMaskPrefix)) {
        notMasks.add(e.substring(notMaskPrefix.length));
      } else if (e.startsWith(vpaPrefix)) {
        vpas.add(e.substring(vpaPrefix.length));
      } else if (e.startsWith(payeePrefix)) {
        payees.add(e.substring(payeePrefix.length));
      } else if (e.startsWith(maskPrefix)) {
        masks.add(e.substring(maskPrefix.length));
      } else {
        final n = OwnerName.parse(e);
        if (n != null) names.add(n);
      }
    }
    return OwnerIdentity(
      names: names,
      vpas: vpas,
      payeeNames: payees,
      accountMasks: masks,
      notNames: notNames,
      notVpas: notVpas,
      notMasks: notMasks,
      familyNames: familyNames,
      familyVpas: familyVpas,
      familyMasks: familyMasks,
      onceSelf: onceSelf,
      onceFamily: onceFamily,
    );
  }

  static const familyPayeePrefix = 'family:payee:';
  static const familyVpaPrefix = 'family:vpa:';
  static const familyMaskPrefix = 'family:mask:';
  static const onceSelfPrefix = 'once:self:';
  static const onceFamilyPrefix = 'once:family:';
  static const notNamePrefix = 'not:name:';
  static const notVpaPrefix = 'not:vpa:';
  static const notMaskPrefix = 'not:mask:';
  static const vpaPrefix = 'vpa:';
  static const payeePrefix = 'payee:';
  static const maskPrefix = 'mask:';

  final List<OwnerName> names;

  /// UPI handles the person marked as their own.
  final Set<String> vpas;

  /// Names the person marked as their own ("this payee is me").
  final Set<String> payeeNames;

  /// Account digits the person marked as their own.
  final Set<String> accountMasks;

  /// Names, handles and account digits the person said are NOT theirs. These
  /// win over everything else, including a name that matches the owner's own.
  final Set<String> notNames;
  final Set<String> notVpas;
  final Set<String> notMasks;

  /// Family members the person marked. A payment to one of them is a transfer
  /// between people, so it is left out of spending and money in, but it is
  /// never decided automatically: only a person's mark puts a payee here.
  final Set<String> familyNames;
  final Set<String> familyVpas;
  final Set<String> familyMasks;

  /// Single payments the person marked ("only this payment"), by the message
  /// they came from. They apply to that one payment and nothing else.
  final Set<String> onceSelf;
  final Set<String> onceFamily;

  bool get isEmpty =>
      names.isEmpty &&
      vpas.isEmpty &&
      payeeNames.isEmpty &&
      accountMasks.isEmpty &&
      notNames.isEmpty &&
      notVpas.isEmpty &&
      notMasks.isEmpty &&
      familyNames.isEmpty &&
      familyVpas.isEmpty &&
      familyMasks.isEmpty &&
      onceSelf.isEmpty &&
      onceFamily.isEmpty;

  /// The identity as the strings [OwnerIdentity.fromEntries] reads back.
  List<String> toEntries() => [
    for (final n in names) n.toString(),
    for (final v in vpas) '$vpaPrefix$v',
    for (final p in payeeNames) '$payeePrefix$p',
    for (final m in accountMasks) '$maskPrefix$m',
    for (final n in notNames) '$notNamePrefix$n',
    for (final v in notVpas) '$notVpaPrefix$v',
    for (final m in notMasks) '$notMaskPrefix$m',
    for (final n in familyNames) '$familyPayeePrefix$n',
    for (final v in familyVpas) '$familyVpaPrefix$v',
    for (final m in familyMasks) '$familyMaskPrefix$m',
    for (final k in onceSelf) '$onceSelfPrefix$k',
    for (final k in onceFamily) '$onceFamilyPrefix$k',
  ];

  /// True when the payee is one the person marked as family.
  bool isFamilyPayee({String? name, String? vpa, String? mask}) {
    final v = vpa?.trim().toLowerCase();
    if (v != null && v.contains('@') && familyVpas.contains(v)) return true;
    final m = mask?.trim();
    if (m != null && familyMasks.contains(m)) return true;
    if (name != null && !name.contains('@')) {
      final t = _words(name);
      if (t.length >= 2 && familyNames.contains(t.join(' '))) return true;
    }
    return false;
  }

  /// True when this one payment (by its source message) was marked as a
  /// transfer between the person's own accounts.
  bool isMarkedSelfOnce(String? sourceKey) =>
      sourceKey != null && onceSelf.contains(sourceKey);

  bool isMarkedFamilyOnce(String? sourceKey) =>
      sourceKey != null && onceFamily.contains(sourceKey);

  /// True when a payment is a transfer to family, by a payee mark or a mark on
  /// this single payment. Never true for the person's own accounts.
  bool isFamilyTransfer({
    String? name,
    String? vpa,
    String? mask,
    String? sourceKey,
  }) =>
      isMarkedFamilyOnce(sourceKey) ||
      isFamilyPayee(name: name, vpa: vpa, mask: mask);

  /// True when a printed name (or a handle printed as a name) is the owner.
  bool matchesName(String? printed) {
    if (printed == null || printed.trim().isEmpty) return false;
    if (printed.contains('@')) return matchesVpa(printed);
    final t = _words(printed);
    if (t.isEmpty) return false;
    if (notNames.contains(t.join(' '))) return false;
    if (payeeNames.contains(t.join(' ')) && t.length >= 2) return true;
    for (final n in names) {
      if (_nameMatches(n, t)) return true;
    }
    return false;
  }

  /// True when a UPI handle is one the person marked, or is built from the
  /// owner's own name ("ishaanrangnekar-2@bank", "rangnekarishaan@bank").
  bool matchesVpa(String? vpa) {
    if (vpa == null) return false;
    final v = vpa.trim().toLowerCase();
    if (v.isEmpty || notVpas.contains(v)) return false;
    if (vpas.contains(v)) return true;
    final at = v.indexOf('@');
    final local = (at < 0 ? v : v.substring(0, at)).replaceAll(_notLowerLetter, '');
    if (local.length < 6) return false;
    for (final n in names) {
      for (final form in n.runTogether) {
        if (local == form.toLowerCase()) return true;
      }
    }
    return false;
  }

  /// True when the person said this printed name, handle or account is NOT
  /// theirs.
  bool rejectsName(String? printed) {
    if (printed == null) return false;
    if (printed.contains('@')) return rejectsVpa(printed);
    final t = _words(printed);
    return t.isNotEmpty && notNames.contains(t.join(' '));
  }

  bool rejectsVpa(String? vpa) =>
      vpa != null && notVpas.contains(vpa.trim().toLowerCase());

  bool rejectsAccountMask(String? mask) =>
      mask != null && notMasks.contains(mask.trim());

  /// True when an account's last digits are one the person marked.
  bool matchesAccountMask(String? mask) {
    if (mask == null) return false;
    final m = mask.trim();
    return m.isNotEmpty && !notMasks.contains(m) && accountMasks.contains(m);
  }

  static bool _nameMatches(OwnerName o, List<String> t) {
    // Run together or clipped by the bank: "ISHAANRANGNEKAR", "ISHAANDATTATRAYRANG".
    final g = t.join();
    if (g.length >= 8) {
      for (final form in o.runTogether) {
        // Run together as one word, or a clipped run-together word. A print
        // of several words is judged word by word below, never by its prefix.
        if (g == form ||
            (t.length == 1 && g.length < form.length && form.startsWith(g))) {
          // A clipped print must still carry the first name in full.
          if (g.startsWith(o.first) || g.startsWith(o.last + o.first)) {
            return true;
          }
        }
      }
    }
    if (t.length < 2) return false;

    // Say what each printed word is, in the owner's name.
    final used = <String>[]; // owner words already explained
    int? firstAt, lastAt;
    var lastClipped = false;
    var lastInitial = false;
    var middleFull = false;
    final unknownAt = <int>[];
    for (var i = 0; i < t.length; i++) {
      final w = t[i];
      if (w == o.first && firstAt == null) {
        firstAt = i;
        used.add(w);
      } else if (w == o.last && lastAt == null) {
        lastAt = i;
        used.add(w);
      } else if (o.middles.contains(w) && !used.contains(w)) {
        middleFull = true;
        used.add(w);
      } else if (w.length == 1) {
        // An initial stands for a middle name or the last name, never the first.
        final j = o.middles.indexWhere((m) => m.startsWith(w) && !used.contains(m));
        if (j >= 0) {
          used.add(o.middles[j]);
        } else if (o.last.startsWith(w) && lastAt == null && !lastInitial) {
          lastInitial = true;
          lastAt = i;
        } else if (o.first.startsWith(w) && firstAt == null) {
          return false;
        } else {
          unknownAt.add(i);
        }
      } else if (i == t.length - 1 &&
          lastAt == null &&
          w.length >= 3 &&
          o.last.length > w.length &&
          o.last.startsWith(w)) {
        // The bank cut the print short in the middle of the last name.
        lastClipped = true;
        lastAt = i;
      } else {
        unknownAt.add(i);
      }
    }
    if (firstAt == null) return false;

    final lastFull = lastAt != null && !lastClipped && !lastInitial;
    var evidence = lastFull || middleFull;
    if (lastClipped) evidence = true;
    if (lastInitial && !middleFull) evidence = false;
    if (lastInitial && middleFull) evidence = true;
    if (!evidence) return false;

    // A word the owner's name does not explain is another person (a different
    // middle or last name, or a name with more words than the owner gave). It is
    // never guessed: when the bank prints a middle name the owner did not give,
    // the person confirms it once and it is remembered ([OwnerIdentity.payeeNames]),
    // or the name is learned from their own messages.
    return unknownAt.isEmpty;
  }
}
