import 'dart:convert';

import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';

/// Reads the categories a person confirmed or corrected before, from the v2
/// ledger (`v2_ledger`). An entry counts only when its `categorySource` is
/// `user` or `history_confirmed`; a category that was only assigned
/// automatically never counts. See `confirmedHistoryFromLedger`.
class ConfirmedCategoryHistory {
  ConfirmedCategoryHistory(this.database, {required this.namespace, TaxonomyRegistry? registry})
      : registry = registry ?? TaxonomyRegistry.v1;

  final AppDatabase database;
  final String namespace;
  final TaxonomyRegistry registry;

  /// Merchant key to the most recently confirmed category slug. Rows that no
  /// longer parse as ledger entries are skipped.
  Map<String, String> load() {
    final rows = database.db.select(
      'SELECT payload FROM v2_ledger WHERE namespace = ? '
      "AND json_extract(payload, '\$.categorySource') IN ('user', 'history_confirmed')",
      [namespace],
    );
    final entries = <LedgerEntry>[];
    for (final row in rows) {
      try {
        final json = jsonDecode(row['payload'] as String);
        if (json is Map) entries.add(LedgerEntry.fromJson(json.cast<String, Object?>()));
      } on Object {
        continue;
      }
    }
    return confirmedHistoryFromLedger(entries, registry: registry);
  }
}
