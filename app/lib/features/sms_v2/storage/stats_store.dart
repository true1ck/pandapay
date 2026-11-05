import 'package:sqlite3/sqlite3.dart';

/// Cumulative daily counts scoped to the account that produced them.
class StatsStore {
  const StatsStore(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  /// The rule id a count is reported against. A shared rule reports as itself.
  /// A private AI rule on this phone (`AI-<layout hash>:local:<phone hash>`)
  /// reports as `AI-<layout hash>`, the same id on every phone, so the console
  /// can show how the draft fares. Personal rules and any other private rule
  /// are not reported.
  static String? reportedRuleId(String ruleId) {
    if (ruleId.startsWith('PERSONAL-')) return null;
    final at = ruleId.indexOf(':local:');
    if (at < 0) return ruleId;
    final base = ruleId.substring(0, at);
    return base.startsWith('AI-') ? base : null;
  }

  void record({
    required DateTime at,
    required String ruleId,
    required int ruleVersion,
    bool toReview = false,
    bool corrected = false,
  }) {
    final day = at.toUtc().toIso8601String().substring(0, 10);
    db.execute(
      '''
INSERT INTO v2_rule_stats_by_account(namespace,day,rule_id,rule_version,hits,to_review,corrected)
VALUES(?,?,?,?,1,?,?) ON CONFLICT(namespace,day,rule_id,rule_version) DO UPDATE SET
 hits=hits+1, to_review=to_review+excluded.to_review, corrected=corrected+excluded.corrected
''',
      [
        namespace,
        day,
        ruleId,
        ruleVersion,
        toReview ? 1 : 0,
        corrected ? 1 : 0,
      ],
    );
  }

  void correction({
    required DateTime at,
    required String ruleId,
    required int ruleVersion,
  }) {
    final reported = reportedRuleId(ruleId);
    if (ruleVersion < 1 || reported == null) return;
    final day = at.toUtc().toIso8601String().substring(0, 10);
    db.execute(
      'UPDATE v2_rule_stats_by_account SET corrected=corrected+1 WHERE namespace=? AND day=? AND rule_id=? AND rule_version=?',
      [namespace, day, reported, ruleVersion],
    );
  }

  Map<String, Object?>? payload(
    DateTime now, {
    required String appVersion,
    required int bundleVersion,
  }) {
    final day = now.toUtc().toIso8601String().substring(0, 10);
    final rows = db.select(
      'SELECT * FROM v2_rule_stats_by_account WHERE namespace=? AND day=? ORDER BY rule_id,rule_version',
      [namespace, day],
    );
    if (rows.isEmpty) return null;
    return {
      'day': day,
      'appVersion': appVersion,
      'bundleVersion': bundleVersion,
      'stats': [
        for (final row in rows)
          {
            'ruleId': row['rule_id'],
            'ruleVersion': row['rule_version'],
            'hits': row['hits'],
            'toReview': row['to_review'],
            'corrected': row['corrected'],
          },
      ],
    };
  }
}
