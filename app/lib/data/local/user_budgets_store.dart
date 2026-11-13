import 'dart:convert';

import 'app_database.dart';

/// WP-C7: budgets created on this phone that the server has not confirmed yet
/// (table `user_budgets`, `LocalFirstSchema` migration 2). The queued
/// `budget_save` command delivers them; [BudgetsLocal] drops a row once the
/// server list carries the same target. Not a send queue: nothing is lost if
/// a row is dropped early, the command still carries the data.
class UserBudgetsStore {
  UserBudgetsStore(this._db, this.namespace);
  final AppDatabase _db;
  final String namespace;

  void put(String id, Map<String, Object?> budget) => _db.db.execute(
    'INSERT OR REPLACE INTO user_budgets VALUES (?,?,?,?)',
    [
      namespace,
      id,
      jsonEncode(budget),
      DateTime.now().millisecondsSinceEpoch,
    ],
  );

  Map<String, Map<String, Object?>> all() => {
    for (final row in _db.db.select(
      'SELECT id, payload FROM user_budgets WHERE namespace=? ORDER BY edited_at',
      [namespace],
    ))
      row['id'] as String: (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>(),
  };

  void remove(String id) => _db.db.execute(
    'DELETE FROM user_budgets WHERE namespace=? AND id=?',
    [namespace, id],
  );

  /// Drops every local row for the same (scope, ref, period) target.
  void removeTarget(String scope, String? ref, String period) {
    for (final e in all().entries) {
      final b = e.value;
      if (b['scope'] == scope &&
          (b['scopeRefId'] as String? ?? '') == (ref ?? '') &&
          b['period'] == period) {
        remove(e.key);
      }
    }
  }
}
