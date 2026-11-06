import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:sqlite3/sqlite3.dart';

/// A person's own name for a shop. Keyed on the name the SMS prints, so every
/// SMS from that shop shows the person's name, whatever they typed.
class PersonalMerchantAlias {
  const PersonalMerchantAlias({
    required this.printedKey,
    required this.name,
    required this.since,
  });

  /// `normalizeMerchantText` of the name as printed in the SMS.
  final String printedKey;

  /// What the person calls the shop.
  final String name;

  /// The name applies to SMS received at or after this time. Going back to
  /// the beginning of time is what "also change the earlier ones" does.
  final DateTime since;

  bool appliesTo(DateTime receivedAt) => !receivedAt.toUtc().isBefore(since);
}

/// The aliases of one account, in `v2_personal_merchant_alias`.
class PersonalMerchantAliases {
  PersonalMerchantAliases(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  static final DateTime beginning = DateTime.utc(1970);
  static const maxNameLength = 80;

  Map<String, PersonalMerchantAlias> load() => {
    for (final row in db.select(
      'SELECT printed_key, display_name, since FROM v2_personal_merchant_alias WHERE namespace=?',
      [namespace],
    ))
      row['printed_key'] as String: PersonalMerchantAlias(
        printedKey: row['printed_key'] as String,
        name: row['display_name'] as String,
        since: DateTime.parse(row['since'] as String),
      ),
  };

  PersonalMerchantAlias? get(String printedKey) => load()[printedKey];

  /// Stores [name] for the shop printed as [printedName]. Returns the alias
  /// that was there before, or null, so a change can be undone.
  PersonalMerchantAlias? save({
    required String printedName,
    required String name,
    required DateTime since,
    DateTime? now,
  }) {
    final key = normalizeMerchantText(printedName);
    final shown = name.trim();
    if (key.isEmpty) throw ArgumentError('The shop has no printed name');
    if (shown.isEmpty || shown.length > maxNameLength) {
      throw ArgumentError('Use a name of 1 to $maxNameLength characters');
    }
    final previous = get(key);
    db.execute(
      '''
INSERT INTO v2_personal_merchant_alias(namespace, printed_key, display_name, since, updated_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(namespace, printed_key) DO UPDATE SET
  display_name = excluded.display_name, since = excluded.since, updated_at = excluded.updated_at
''',
      [
        namespace,
        key,
        shown,
        since.toUtc().toIso8601String(),
        (now ?? DateTime.now()).toUtc().toIso8601String(),
      ],
    );
    return previous;
  }

  /// Puts an alias back as it was ([previous] null removes it).
  void restore(String printedKey, PersonalMerchantAlias? previous) {
    if (previous == null) {
      remove(printedKey);
    } else {
      save(
        printedName: printedKey,
        name: previous.name,
        since: previous.since,
      );
    }
  }

  void remove(String printedKey) => db.execute(
    'DELETE FROM v2_personal_merchant_alias WHERE namespace=? AND printed_key=?',
    [namespace, printedKey],
  );
}
