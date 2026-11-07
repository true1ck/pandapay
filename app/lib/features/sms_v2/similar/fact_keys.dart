import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:sqlite3/sqlite3.dart';

/// The two keys stored beside every fact so that "which other transactions
/// look like this one" is an indexed lookup instead of a read of every fact.
class FactKey {
  const FactKey({this.merchantKey, this.ruleId});

  /// The shop as the SMS printed it, normalised the way personal category
  /// rules are keyed. Null for a fact the person wrote (their own edit), a fact
  /// with no shop, and anything else that must never match as "similar".
  final String? merchantKey;

  /// The rule that read the SMS.
  final String? ruleId;
}

abstract final class FactKeys {
  static FactKey of(Fact fact) {
    final isMachine = fact.provenance.engine != Engine.user;
    final name = fact.counterparty?.name;
    final key = isMachine && name != null ? normalizeMerchantText(name) : '';
    return FactKey(
      merchantKey: key.isEmpty ? null : key,
      ruleId: isMachine ? fact.provenance.ruleId : null,
    );
  }

  /// How many facts of the account still wait for their keys.
  static int pending(Database db, String namespace) =>
      db.select(
            'SELECT COUNT(*) AS n FROM v2_facts WHERE namespace=? AND keyed=0',
            [namespace],
          ).single['n']
          as int;

  /// Writes the keys of up to [limit] facts that were stored before the
  /// columns existed. Returns how many were done; call again until it
  /// returns 0. A chunk is small so it never holds the database for long.
  static int backfill(Database db, String namespace, {int limit = 500}) {
    final rows = db.select(
      'SELECT fact_id, payload FROM v2_facts WHERE namespace=? AND keyed=0 LIMIT ?',
      [namespace, limit],
    );
    if (rows.isEmpty) return 0;
    db.execute('SAVEPOINT v2_fact_keys');
    try {
      for (final row in rows) {
        FactKey key;
        try {
          key = of(
            Fact.fromJson(
              (jsonDecode(row['payload'] as String) as Map)
                  .cast<String, Object?>(),
            ),
          );
        } catch (_) {
          // A fact that no longer parses can never match; mark it done.
          key = const FactKey();
        }
        db.execute(
          'UPDATE v2_facts SET merchant_key=?, rule_id=?, keyed=1 WHERE namespace=? AND fact_id=?',
          [key.merchantKey, key.ruleId, namespace, row['fact_id']],
        );
      }
      db.execute('RELEASE v2_fact_keys');
    } catch (_) {
      db.execute('ROLLBACK TO v2_fact_keys');
      db.execute('RELEASE v2_fact_keys');
      rethrow;
    }
    return rows.length;
  }
}
