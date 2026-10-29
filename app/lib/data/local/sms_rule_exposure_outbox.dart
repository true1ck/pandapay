import 'app_database.dart';

/// Durable, privacy-safe feedback for assigned candidate rules. It contains
/// only hashes, labels, and comparison metadata; no SMS text or extracted
/// financial values. Assignment identity is retained so an offline event can
/// still be verified after a candidate advances to another stage.
class SmsRuleExposureOutbox {
  final AppDatabase database;
  static final _initialized = <Object>{};
  SmsRuleExposureOutbox(this.database) {
    if (_initialized.add(database.db)) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_rule_exposure_outbox (
        namespace TEXT NOT NULL, candidate_id TEXT NOT NULL,
        source_key TEXT NOT NULL, stage TEXT NOT NULL,
        stage_version INTEGER NOT NULL DEFAULT 1,
        assignment_id TEXT,
        matched INTEGER NOT NULL, applied INTEGER NOT NULL,
        outcome TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt INTEGER NOT NULL DEFAULT 0,
        delta_outcome TEXT,
        baseline_family TEXT, candidate_family TEXT,
        baseline_disposition TEXT, candidate_disposition TEXT,
        exact_fields_equal INTEGER,
        fact_valid INTEGER, invariant_breach INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(namespace, candidate_id, source_key, stage, stage_version)
      );
    ''');
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_rule_source_attribution (
        namespace TEXT NOT NULL,
        source_key TEXT NOT NULL,
        candidate_id TEXT NOT NULL,
        PRIMARY KEY(namespace, source_key)
      )
    ''');
    for (final statement in [
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN stage_version INTEGER NOT NULL DEFAULT 1',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN assignment_id TEXT',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN delta_outcome TEXT',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN baseline_family TEXT',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN candidate_family TEXT',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN baseline_disposition TEXT',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN candidate_disposition TEXT',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN exact_fields_equal INTEGER',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN fact_valid INTEGER',
      'ALTER TABLE sms_rule_exposure_outbox ADD COLUMN invariant_breach INTEGER NOT NULL DEFAULT 0',
    ]) {
      try {
        database.db.execute(statement);
      } catch (_) {}
    }
    }
  }

  void enqueue(String namespace, {
    required String candidateId,
    required String sourceKey,
    required String stage,
    required bool matched,
    required bool applied,
    required String outcome,
    String? assignmentId,
    int stageVersion = 1,
    String? deltaOutcome,
    String? baselineFamily,
    String? candidateFamily,
    String? baselineDisposition,
    String? candidateDisposition,
    bool? exactFieldsEqual,
    bool? factValid,
    bool invariantBreach = false,
  }) {
    if (stageVersion < 1) throw ArgumentError.value(stageVersion, 'stageVersion');
    database.db.execute(
      '''INSERT OR REPLACE INTO sms_rule_exposure_outbox
         (namespace,candidate_id,source_key,stage,stage_version,assignment_id,
          matched,applied,outcome,attempts,next_attempt,delta_outcome,
          baseline_family,candidate_family,baseline_disposition,candidate_disposition,
          exact_fields_equal,fact_valid,invariant_breach)
         VALUES (?,?,?,?,?,?,?,?,?,0,0,?,?,?,?,?,?,?,?)''',
      [namespace, candidateId, sourceKey, stage, stageVersion, assignmentId,
        matched ? 1 : 0, applied ? 1 : 0, outcome, deltaOutcome,
        baselineFamily, candidateFamily, baselineDisposition, candidateDisposition,
        exactFieldsEqual == null ? null : (exactFieldsEqual ? 1 : 0),
        factValid == null ? null : (factValid ? 1 : 0), invariantBreach ? 1 : 0],
    );
    if (applied && matched) {
      database.db.execute(
        'INSERT OR REPLACE INTO sms_rule_source_attribution '
        '(namespace, source_key, candidate_id) VALUES (?,?,?)',
        [namespace, sourceKey, candidateId],
      );
    }
  }

  /// The candidate whose observation actually produced this SMS's decision,
  /// but only when that candidate produced the fact being corrected.
  ///
  /// Attribution is stored per message while corrections are per fact, so
  /// without [family] a two-fact message would blame one candidate for both.
  /// A null [family] (or one the candidate did not produce, such as a
  /// `dismissed` correction) returns null: no attribution is safer than a
  /// wrong one, because the server turns this into negative evidence against
  /// the rule.
  String? appliedCandidateForFact(
    String namespace,
    String sourceKey, {
    required String? family,
  }) {
    if (family == null) return null;
    final rows = database.db.select(
      'SELECT candidate_id FROM sms_rule_exposure_outbox '
      'WHERE namespace=? AND source_key=? AND applied=1 AND matched=1 '
      'AND candidate_family=? LIMIT 1',
      [namespace, sourceKey, family],
    );
    return rows.isEmpty ? null : rows.first['candidate_id'] as String;
  }

  List<Map<String, dynamic>> pending(String namespace, {int limit = 100}) => database.db
      .select(
        'SELECT candidate_id,source_key,stage,stage_version,assignment_id,matched,applied,outcome,delta_outcome,baseline_family,candidate_family,baseline_disposition,candidate_disposition,exact_fields_equal,fact_valid,invariant_breach FROM sms_rule_exposure_outbox WHERE namespace=? AND next_attempt<=? ORDER BY rowid LIMIT ?',
        [namespace, DateTime.now().millisecondsSinceEpoch, limit],
      )
      .map((row) => <String, dynamic>{
            'candidateId': row['candidate_id'],
            'sourceKey': row['source_key'],
            'stage': row['stage'],
            'stageVersion': row['stage_version'],
            'assignmentId': row['assignment_id'],
            'matched': (row['matched'] as int) == 1,
            'applied': (row['applied'] as int) == 1,
            'outcome': row['outcome'],
            'deltaOutcome': row['delta_outcome'],
            'baselineFamily': row['baseline_family'],
            'candidateFamily': row['candidate_family'],
            'baselineDisposition': row['baseline_disposition'],
            'candidateDisposition': row['candidate_disposition'],
            'exactFieldsEqual': row['exact_fields_equal'] == null ? null : (row['exact_fields_equal'] as int) == 1,
            'factValid': row['fact_valid'] == null ? null : (row['fact_valid'] as int) == 1,
            'invariantBreach': (row['invariant_breach'] as int? ?? 0) == 1,
          })
      .toList();

  void acknowledge(String namespace, String candidateId, String sourceKey, String stage, {int stageVersion = 1}) {
    database.db.execute(
      'DELETE FROM sms_rule_exposure_outbox WHERE namespace=? AND candidate_id=? AND source_key=? AND stage=? AND stage_version=?',
      [namespace, candidateId, sourceKey, stage, stageVersion],
    );
  }

  void failed(String namespace, String candidateId, String sourceKey, String stage, {int stageVersion = 1}) {
    database.db.execute(
      "UPDATE sms_rule_exposure_outbox SET attempts=attempts+1, next_attempt=? + MIN(1800000,30000 * (1 << MIN(attempts,6))) WHERE namespace=? AND candidate_id=? AND source_key=? AND stage=? AND stage_version=?",
      [DateTime.now().millisecondsSinceEpoch, namespace, candidateId, sourceKey, stage, stageVersion],
    );
  }

  void clear(String namespace) {
    database.db.execute(
      'DELETE FROM sms_rule_exposure_outbox WHERE namespace=?',
      [namespace],
    );
    database.db.execute(
      'DELETE FROM sms_rule_source_attribution WHERE namespace=?',
      [namespace],
    );
  }
}
