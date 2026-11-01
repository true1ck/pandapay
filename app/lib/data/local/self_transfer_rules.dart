import '../self_transfer.dart';
import 'app_database.dart';

/// Private device rules, independent of shared-learning consent and uploads.
class SelfTransferRules {
  final AppDatabase database;
  final String namespace;
  SelfTransferRules(this.database, {required this.namespace}) {
    database.db.execute('''CREATE TABLE IF NOT EXISTS user_self_transfer_rules (
      namespace TEXT NOT NULL, identity TEXT NOT NULL, bank TEXT NOT NULL,
      account_last4 TEXT NOT NULL, PRIMARY KEY(namespace, identity))''');
  }

  void remember({
    required String sender,
    required String body,
    required SelfTransferDestination destination,
  }) {
    final key = selfTransferKey(sender, body);
    if (key == null) return;
    final existing = database.db.select(
      'SELECT bank, account_last4 FROM user_self_transfer_rules WHERE namespace=? AND identity=?',
      [namespace, key],
    );
    if (existing.isNotEmpty &&
        (existing.first['bank'] != destination.bank ||
            existing.first['account_last4'] != destination.accountLast4)) {
      // A reassignment is not safe to learn implicitly. Removing the local
      // rule forces the next matching alert back through explicit review.
      forget(sender: sender, body: body);
      return;
    }
    database.db.execute(
      'INSERT OR REPLACE INTO user_self_transfer_rules VALUES (?,?,?,?)',
      [namespace, key, destination.bank, destination.accountLast4],
    );
  }

  void forget({required String sender, required String body}) {
    final key = selfTransferKey(sender, body);
    if (key != null) {
      database.db.execute(
        'DELETE FROM user_self_transfer_rules WHERE namespace=? AND identity=?',
        [namespace, key],
      );
    }
  }

  Map<String, SelfTransferDestination> load() => {
    for (final row in database.db.select(
      'SELECT * FROM user_self_transfer_rules WHERE namespace=?',
      [namespace],
    ))
      row['identity'] as String: SelfTransferDestination(
        bank: row['bank'] as String,
        accountLast4: row['account_last4'] as String,
      ),
  };

  /// Replaces the account-scoped cache from the authenticated server snapshot.
  /// The caller only invokes this when the migration-backed endpoint is
  /// available; a temporary 503 must never erase an existing offline rule.
  void replaceRemote(List<Map<String, dynamic>> remote) {
    final normalized = <String, SelfTransferDestination>{};
    final destinationsByIdentity = <String, Set<String>>{};
    for (final row in remote) {
      final sender = row['sourceSender'];
      final source = row['sourceAccountLast4'];
      final party = row['party'];
      final bank = row['bank'];
      final account = row['accountLast4'];
      if (sender is! String || source is! String || party is! String ||
          bank is! String || account is! String ||
          !RegExp(r'^\d{4}$').hasMatch(source) ||
          !RegExp(r'^\d{4}$').hasMatch(account)) {
        continue;
      }
      final identity = selfTransferIdentityKey(
        sourceSender: sender,
        sourceAccountLast4: source,
        party: party,
      );
      final destination = SelfTransferDestination(accountLast4: account, bank: bank);
      final destinationKey = '${destination.bank}:${destination.accountLast4}';
      destinationsByIdentity.putIfAbsent(identity, () => <String>{})
        .add(destinationKey);
      normalized[identity] = destination;
    }
    database.db.execute(
      'DELETE FROM user_self_transfer_rules WHERE namespace=?',
      [namespace],
    );
    for (final entry in normalized.entries) {
      // The server intentionally keeps conflicting confirmations visible so
      // new imports fall back to review. Never collapse that ambiguity on a
      // device by letting the last row win.
      if (destinationsByIdentity[entry.key]?.length != 1) continue;
      database.db.execute(
        'INSERT INTO user_self_transfer_rules VALUES (?,?,?,?)',
        [namespace, entry.key, entry.value.bank, entry.value.accountLast4],
      );
    }
  }
}
