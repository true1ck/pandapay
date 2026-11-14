import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Why an entry is in the owner's identity.
enum OwnerEntrySource {
  /// The person typed their name.
  user,

  /// The person marked a payment, payee or account as their own (or rejected
  /// one with "not me").
  marked,

  /// Learned from the greetings in their own messages.
  inferred,

  /// An inferred name the person removed. Kept so it is not learned again.
  dismissed,
}

/// One row the settings screen can show and remove.
class OwnerEntry {
  const OwnerEntry({required this.entry, required this.source});

  /// The string the linker reads (see [OwnerIdentity.fromEntries]).
  final String entry;
  final OwnerEntrySource source;

  bool get isName => !entry.contains(':');
}

/// Who the account owner is, for one account (`v2_owner_identity`).
///
/// Three sources feed it, strongest first: what the person typed or marked,
/// then the name on their profile, then names learned from their greetings.
/// The linker gets all of it as plain strings ([entries]), so the capture
/// isolate needs nothing new.
class OwnerIdentityStore {
  OwnerIdentityStore(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  /// The strings the linker reads: the profile name (when it is a real name),
  /// every typed, marked and learned entry. Dismissed names are not included.
  List<String> entries({String? profileName}) {
    final out = <String>[];
    if (profileName != null && OwnerName.parse(profileName) != null) {
      out.add(profileName);
    }
    for (final e in list()) {
      if (e.source != OwnerEntrySource.dismissed) out.add(e.entry);
    }
    return out;
  }

  List<OwnerEntry> list() => [
    for (final row in db.select(
      'SELECT entry, source FROM v2_owner_identity WHERE namespace=? ORDER BY created_at, entry',
      [namespace],
    ))
      OwnerEntry(
        entry: row['entry'] as String,
        source: OwnerEntrySource.values.firstWhere(
          (s) => s.name == row['source'],
          orElse: () => OwnerEntrySource.user,
        ),
      ),
  ];

  /// The identity the linker would build from [entries].
  OwnerIdentity identity({String? profileName}) =>
      OwnerIdentity.fromEntries(entries(profileName: profileName));

  void _put(String entry, OwnerEntrySource source, DateTime now) => db.execute(
    '''
INSERT INTO v2_owner_identity(namespace, entry, source, created_at) VALUES (?,?,?,?)
ON CONFLICT(namespace, entry) DO UPDATE SET source=excluded.source
''',
    [namespace, entry, source.name, now.toUtc().toIso8601String()],
  );

  void _delete(String entry) => db.execute(
    'DELETE FROM v2_owner_identity WHERE namespace=? AND entry=?',
    [namespace, entry],
  );

  /// The person typed their name. Needs a first and a last name; throws
  /// [ArgumentError] otherwise, so the screen can say so.
  OwnerName addName({
    required String first,
    String? middle,
    required String last,
    DateTime? now,
  }) {
    final name = OwnerName.fromParts(first: first, middle: middle, last: last);
    if (name == null) {
      throw ArgumentError('Enter a first name and a last name');
    }
    _put(name.toString(), OwnerEntrySource.user, now ?? DateTime.now());
    // Typing a name the person had dismissed brings it back.
    _delete('${OwnerIdentity.notNamePrefix}${name.toString()}');
    return name;
  }

  /// The person said this printed name, handle or account is theirs.
  void markOwn({String? name, String? vpa, String? mask, DateTime? now}) {
    final at = now ?? DateTime.now();
    final n = name?.trim();
    if (n != null && OwnerName.parse(n) != null) {
      final words = OwnerIdentity(payeeNames: [n]).payeeNames;
      for (final w in words) {
        _put('${OwnerIdentity.payeePrefix}$w', OwnerEntrySource.marked, at);
        _delete('${OwnerIdentity.notNamePrefix}$w');
        _delete('${OwnerIdentity.familyPayeePrefix}$w');
      }
    }
    final v = vpa?.trim().toLowerCase();
    if (v != null && v.contains('@')) {
      _put('${OwnerIdentity.vpaPrefix}$v', OwnerEntrySource.marked, at);
      _delete('${OwnerIdentity.notVpaPrefix}$v');
      _delete('${OwnerIdentity.familyVpaPrefix}$v');
    }
    final m = mask?.trim();
    if (m != null && RegExp(r'^\d{4,}$').hasMatch(m)) {
      _put('${OwnerIdentity.maskPrefix}$m', OwnerEntrySource.marked, at);
      _delete('${OwnerIdentity.notMaskPrefix}$m');
      _delete('${OwnerIdentity.familyMaskPrefix}$m');
    }
  }

  /// The person took back "this payee is mine": the marks go, nothing is added.
  void unmarkOwn({String? name, String? vpa, String? mask}) {
    final n = name?.trim();
    if (n != null) {
      for (final w in OwnerIdentity(payeeNames: [n]).payeeNames) {
        _delete('${OwnerIdentity.payeePrefix}$w');
      }
    }
    final v = vpa?.trim().toLowerCase();
    if (v != null) _delete('${OwnerIdentity.vpaPrefix}$v');
    final m = mask?.trim();
    if (m != null) _delete('${OwnerIdentity.maskPrefix}$m');
  }

  /// The person said this payee is a family member. A payment to or from them
  /// is a transfer between people, left out of spending and money in. Replaces
  /// any "mine" or "not mine" mark on the same payee.
  void markFamily({String? name, String? vpa, String? mask, DateTime? now}) {
    final at = now ?? DateTime.now();
    final n = name?.trim();
    if (n != null && OwnerName.parse(n) != null) {
      for (final w in OwnerIdentity(familyNames: [n]).familyNames) {
        _put('${OwnerIdentity.familyPayeePrefix}$w', OwnerEntrySource.marked, at);
        _delete('${OwnerIdentity.payeePrefix}$w');
        _delete('${OwnerIdentity.notNamePrefix}$w');
      }
    }
    final v = vpa?.trim().toLowerCase();
    if (v != null && v.contains('@')) {
      _put('${OwnerIdentity.familyVpaPrefix}$v', OwnerEntrySource.marked, at);
      _delete('${OwnerIdentity.vpaPrefix}$v');
      _delete('${OwnerIdentity.notVpaPrefix}$v');
    }
    final m = mask?.trim();
    if (m != null && RegExp(r'^\d{4,}$').hasMatch(m)) {
      _put('${OwnerIdentity.familyMaskPrefix}$m', OwnerEntrySource.marked, at);
      _delete('${OwnerIdentity.maskPrefix}$m');
      _delete('${OwnerIdentity.notMaskPrefix}$m');
    }
  }

  /// Marks, as family, the payees whose printed name strongly looks like the
  /// owner's family ([familyLikeName]). The mark is the same one a person makes
  /// by hand, stored as `inferred` so Settings says it was automatic. A payee
  /// the person already decided on (marked, took back, or said is theirs or not
  /// theirs) is left alone. A weak match is only ever a suggestion on the
  /// payment's screen. Returns how many payees were marked.
  int autoFamily(Iterable<String> payees, {String? profileName, DateTime? now}) {
    final all = entries(profileName: profileName);
    final owners = [for (final e in all) if (!e.contains(':')) e];
    if (owners.isEmpty) return 0;
    final identity = OwnerIdentity.fromEntries(all);
    final known = {for (final e in list()) e.entry};
    var n = 0;
    for (final p in payees) {
      if (familyLikeName(p, owners) != FamilyMatch.strong ||
          identity.matchesName(p)) {
        continue;
      }
      // A one-word name cannot be remembered as a payee, so it stays a suggestion.
      final key = OwnerIdentity(familyNames: [p]).familyNames;
      if (key.isEmpty) continue;
      final w = key.single;
      if ([
        '${OwnerIdentity.familyPayeePrefix}$w',
        '${OwnerIdentity.payeePrefix}$w',
        '${OwnerIdentity.notNamePrefix}$w',
      ].any(known.contains)) {
        continue;
      }
      _put('${OwnerIdentity.familyPayeePrefix}$w', OwnerEntrySource.inferred, now ?? DateTime.now());
      n++;
    }
    return n;
  }

  /// The person took the family mark back for this payee. It is remembered as
  /// dismissed, so [autoFamily] never puts it back.
  void unmarkFamily({String? name, String? vpa, String? mask}) {
    final n = name?.trim();
    if (n != null) {
      for (final w in OwnerIdentity(familyNames: [n]).familyNames) {
        _put('${OwnerIdentity.familyPayeePrefix}$w', OwnerEntrySource.dismissed, DateTime.now());
      }
    }
    final v = vpa?.trim().toLowerCase();
    if (v != null) _delete('${OwnerIdentity.familyVpaPrefix}$v');
    final m = mask?.trim();
    if (m != null) _delete('${OwnerIdentity.familyMaskPrefix}$m');
  }

  /// "Only this payment": the person marked one payment (by the message it came
  /// from) as a transfer to family, or between their own accounts, without
  /// remembering the payee. Replaces an earlier single-payment mark.
  void markOnce({required String sourceKey, required bool family, DateTime? now}) {
    final key = sourceKey.trim();
    if (key.isEmpty) return;
    final self = '${OwnerIdentity.onceSelfPrefix}$key';
    final fam = '${OwnerIdentity.onceFamilyPrefix}$key';
    _put(family ? fam : self, OwnerEntrySource.marked, now ?? DateTime.now());
    _delete(family ? self : fam);
  }

  /// Takes back a single-payment mark.
  void clearOnce(String sourceKey) {
    final key = sourceKey.trim();
    _delete('${OwnerIdentity.onceSelfPrefix}$key');
    _delete('${OwnerIdentity.onceFamilyPrefix}$key');
  }

  /// The identity for projection: marks and typed names only, no profile name.
  /// An account whose identity table is not there yet has made no marks.
  OwnerIdentity marksOnly() {
    try {
      return identity();
    } catch (_) {
      return OwnerIdentity();
    }
  }

  /// The person said this printed name, handle or account is NOT theirs, even
  /// if it looks like their name. Undoes a mark made earlier.
  void markNotOwn({String? name, String? vpa, String? mask, DateTime? now}) {
    final at = now ?? DateTime.now();
    final n = name?.trim();
    if (n != null && n.isNotEmpty) {
      final key = OwnerIdentity(notNames: [n]).notNames;
      for (final w in key) {
        _put('${OwnerIdentity.notNamePrefix}$w', OwnerEntrySource.marked, at);
        _delete('${OwnerIdentity.payeePrefix}$w');
      }
    }
    final v = vpa?.trim().toLowerCase();
    if (v != null && v.contains('@')) {
      _put('${OwnerIdentity.notVpaPrefix}$v', OwnerEntrySource.marked, at);
      _delete('${OwnerIdentity.vpaPrefix}$v');
    }
    final m = mask?.trim();
    if (m != null && RegExp(r'^\d{4,}$').hasMatch(m)) {
      _put('${OwnerIdentity.notMaskPrefix}$m', OwnerEntrySource.marked, at);
      _delete('${OwnerIdentity.maskPrefix}$m');
    }
  }

  /// Removes one row from the settings list. A learned name is remembered as
  /// dismissed so it does not come back; anything else is simply deleted.
  void remove(String entry, {DateTime? now}) {
    final row = list().where((e) => e.entry == entry).firstOrNull;
    if (row == null) return;
    if (row.source == OwnerEntrySource.inferred) {
      _put(entry, OwnerEntrySource.dismissed, now ?? DateTime.now());
    } else {
      _delete(entry);
    }
  }

  // ---- learning the name from greetings ----

  OwnerNameSignals _signals() {
    final rows = db.select(
      'SELECT payload FROM v2_owner_signals WHERE namespace=?',
      [namespace],
    );
    if (rows.isEmpty) return OwnerNameSignals();
    try {
      return OwnerNameSignals.fromJson(
        (jsonDecode(rows.first['payload'] as String) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return OwnerNameSignals();
    }
  }

  /// Notes the greetings in a batch of NEW messages (one write for the batch),
  /// then updates the learned names. Returns true when the set of learned
  /// names changed, so the caller can re-check history.
  bool noteGreetings(
    Iterable<({String body, String sender})> messages, {
    DateTime? now,
  }) {
    var any = false;
    final signals = _signals();
    for (final m in messages) {
      final lower = m.body;
      if (lower.length < 12) continue;
      final name = greetingName(lower);
      if (name == null) continue;
      signals.add(name, m.sender);
      any = true;
    }
    if (!any) return false;
    final at = (now ?? DateTime.now()).toUtc().toIso8601String();
    db.execute(
      '''
INSERT INTO v2_owner_signals(namespace, payload, updated_at) VALUES (?,?,?)
ON CONFLICT(namespace) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at
''',
      [namespace, jsonEncode(signals.toJson()), at],
    );
    return refreshInferred(signals: signals, now: now);
  }

  /// Replaces the learned names with those the signals now support, except
  /// the ones the person dismissed. Returns true when the learned set changed.
  bool refreshInferred({OwnerNameSignals? signals, DateTime? now}) {
    final believed = (signals ?? _signals()).promoted();
    final current = list();
    final dismissed = {
      for (final e in current)
        if (e.source == OwnerEntrySource.dismissed) e.entry,
    };
    final typed = [
      for (final e in current)
        if (e.source == OwnerEntrySource.user && e.isName) OwnerName.parse(e.entry),
    ].whereType<OwnerName>().toSet();
    final want = <String>{
      for (final n in believed)
        if (!dismissed.contains(n.toString()) && !typed.contains(n)) n.toString(),
    };
    final have = {
      for (final e in current)
        // Family payees marked automatically are not learned names.
        if (e.source == OwnerEntrySource.inferred && e.isName) e.entry,
    };
    if (want.length == have.length && want.containsAll(have)) return false;
    final at = now ?? DateTime.now();
    for (final gone in have.difference(want)) {
      _delete(gone);
    }
    for (final added in want.difference(have)) {
      _put(added, OwnerEntrySource.inferred, at);
    }
    return true;
  }
}
