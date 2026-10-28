import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../features/sms_import/sms_background_queue.dart';
import 'app_database.dart';

const smsCaptureNamespaceKey = 'pandapay_app.sms_capture_namespace_v1';

/// Matches api/src/import_source_key.js, including whitespace and sender
/// normalization. Delivery timestamps do not identify a bank transaction.
String smsSourceKey(String namespace, String sender, String body) {
  String normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final account = namespace.startsWith('user:')
      ? namespace.substring(5)
      : namespace;
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            account,
            normalize(sender).toUpperCase(),
            normalize(body),
          ]),
        ),
      )
      .toString();
}

class SmsIntakeEntry {
  final String id;
  final QueuedSms message;
  const SmsIntakeEntry(this.id, this.message);
}

class SmsSourceDecision {
  final String sourceKey;
  final String decision;
  final String state;
  final String reasonCode;
  final String policyVersion;
  final String? parserVersion;
  final int? bundleVersion;
  final int receivedAt;
  final int decidedAt;

  const SmsSourceDecision({
    required this.sourceKey,
    required this.decision,
    required this.state,
    required this.reasonCode,
    required this.policyVersion,
    this.parserVersion,
    this.bundleVersion,
    required this.receivedAt,
    required this.decidedAt,
  });
}

/// Append/ack queue, not read/replace. An SMS arriving during an upload is
/// never overwritten by that upload's old copy of the queue. Failed items
/// remain on disk; there is no drop-oldest limit.
class SmsIntakeRepository {
  final AppDatabase database;
  final DateTime Function() now;
  static final _initialized = <Object>{};
  SmsIntakeRepository(this.database, {DateTime Function()? now})
    : now = now ?? DateTime.now {
    if (_initialized.add(database.db)) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_intake (
        namespace TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL,
        body TEXT NOT NULL, received_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        PRIMARY KEY(namespace, id)
      );
      CREATE TABLE IF NOT EXISTS sms_captured_messages (
        namespace TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL,
        body TEXT NOT NULL, received_at INTEGER NOT NULL,
        repeated_occurrence INTEGER NOT NULL DEFAULT 0,
        processed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(namespace, id)
      );
      CREATE INDEX IF NOT EXISTS sms_captured_by_date
        ON sms_captured_messages(namespace,received_at DESC,id);
      CREATE TABLE IF NOT EXISTS sms_source_decisions (
        namespace TEXT NOT NULL,
        source_key TEXT NOT NULL,
        decision TEXT NOT NULL,
        state TEXT NOT NULL,
        reason_code TEXT NOT NULL,
        policy_version TEXT NOT NULL,
        parser_version TEXT,
        bundle_version INTEGER,
        received_at INTEGER NOT NULL,
        decided_at INTEGER NOT NULL,
        PRIMARY KEY(namespace, source_key)
      );
    ''');
    if (!database.db
        .select('PRAGMA table_info(sms_captured_messages)')
        .any((column) => column['name'] == 'repeated_occurrence')) {
      database.db.execute(
        'ALTER TABLE sms_captured_messages ADD COLUMN repeated_occurrence INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!database.db
        .select('PRAGMA table_info(sms_intake)')
        .any((column) => column['name'] == 'next_attempt')) {
      database.db.execute(
        'ALTER TABLE sms_intake ADD COLUMN next_attempt INTEGER NOT NULL DEFAULT 0',
      );
    }
    database.db.execute(
      'CREATE INDEX IF NOT EXISTS sms_pending_retry ON sms_intake(namespace,next_attempt)',
    );
    }
  }

  SmsSourceDecision? decision(String namespace, String sourceKey) {
    final rows = database.db.select(
      'SELECT source_key, decision, state, reason_code, policy_version, '
      'parser_version, bundle_version, received_at, decided_at '
      'FROM sms_source_decisions WHERE namespace=? AND source_key=? LIMIT 1',
      [namespace, sourceKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SmsSourceDecision(
      sourceKey: row['source_key'] as String,
      decision: row['decision'] as String,
      state: row['state'] as String,
      reasonCode: row['reason_code'] as String,
      policyVersion: row['policy_version'] as String,
      parserVersion: row['parser_version'] as String?,
      bundleVersion: row['bundle_version'] as int?,
      receivedAt: row['received_at'] as int,
      decidedAt: row['decided_at'] as int,
    );
  }

  void recordDecision(
    String namespace, {
    required String sourceKey,
    required String decision,
    required String state,
    required String reasonCode,
    required int receivedAt,
    String? parserVersion,
    int? bundleVersion,
    String policyVersion = 'v1',
  }) {
    database.db.execute(
      'INSERT OR REPLACE INTO sms_source_decisions ('
      'namespace, source_key, decision, state, reason_code, '
      'policy_version, parser_version, bundle_version, received_at, decided_at'
      ') VALUES (?,?,?,?,?,?,?,?,?,?)',
      [
        namespace,
        sourceKey,
        decision,
        state,
        reasonCode,
        policyVersion,
        parserVersion,
        bundleVersion,
        receivedAt,
        now().millisecondsSinceEpoch,
      ],
    );
  }

  void forgetRaw(String namespace, String sourceKey) {
    database.db.execute('DELETE FROM sms_intake WHERE namespace=? AND id=?', [
      namespace,
      sourceKey,
    ]);
    database.db.execute(
      'DELETE FROM sms_captured_messages WHERE namespace=? AND id=?',
      [namespace, sourceKey],
    );
  }

  String capture(String namespace, QueuedSms sms, {int? parserVersion}) {
    final id = smsSourceKey(namespace, sms.sender, sms.body);
    remember(namespace, sms);
    if (wasProcessed(namespace, id, parserVersion: parserVersion)) return id;
    database.db.execute(
      'INSERT OR REPLACE INTO sms_intake(namespace,id,sender,body,received_at) VALUES (?,?,?,?,?)',
      [
        namespace,
        id,
        sms.sender,
        sms.body,
        sms.receivedAt.millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  void remember(String namespace, QueuedSms sms) {
    final sourceKey = smsSourceKey(namespace, sms.sender, sms.body);
    final receivedAt = sms.receivedAt.millisecondsSinceEpoch;
    database.db.execute(
      'INSERT INTO sms_captured_messages(namespace,id,sender,body,received_at,repeated_occurrence) VALUES (?,?,?,?,?,0) '
      'ON CONFLICT(namespace,id) DO UPDATE SET repeated_occurrence='
      'CASE WHEN sms_captured_messages.received_at <> excluded.received_at '
      'THEN 1 ELSE sms_captured_messages.repeated_occurrence END',
      [namespace, sourceKey, sms.sender, sms.body, receivedAt],
    );
  }

  /// True when this deduplicated source key was observed with another delivery
  /// timestamp. Its local record remains deduplicated, but it is unsafe to
  /// attribute a later correction to one particular SMS occurrence.
  bool hasRepeatedOccurrence(String namespace, String sourceKey) =>
      database.db.select(
        'SELECT 1 FROM sms_captured_messages WHERE namespace=? AND id=? AND repeated_occurrence=1 LIMIT 1',
        [namespace, sourceKey],
      ).isNotEmpty;

  /// Returns the original SMS captured on this device for a source key.
  /// Raw text never leaves the device through this read path.
  SmsIntakeEntry? capturedById(String namespace, String id) {
    final rows = database.db.select(
      'SELECT id, sender, body, received_at FROM sms_captured_messages WHERE namespace=? AND id=? LIMIT 1',
      [namespace, id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SmsIntakeEntry(
      row['id'] as String,
      QueuedSms(
        sender: row['sender'] as String,
        body: row['body'] as String,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(row['received_at'] as int),
      ),
    );
  }

  bool wasProcessed(String namespace, String id, {int? parserVersion}) {
    if (parserVersion != null) {
      final rows = database.db.select(
        "SELECT parser_version FROM sms_source_decisions WHERE namespace=? AND source_key=? AND state='final' LIMIT 1",
        [namespace, id],
      );
      if (rows.isNotEmpty) {
        final ver =
            int.tryParse(rows.first['parser_version'] as String? ?? '0') ?? 0;
        return ver >= parserVersion;
      }
      return false;
    }
    return database.db.select(
      'SELECT 1 FROM sms_captured_messages WHERE namespace=? AND id=? AND processed=1 '
      "UNION ALL SELECT 1 FROM sms_source_decisions WHERE namespace=? AND source_key=? AND state='final'",
      [namespace, id, namespace, id],
    ).isNotEmpty;
  }

  List<String> capturedBodies(String namespace, {int limit = 500}) => database
      .db
      .select(
        'SELECT body FROM sms_captured_messages WHERE namespace=? ORDER BY received_at DESC,id LIMIT ?',
        [namespace, limit],
      )
      .map((row) => row['body'] as String)
      .toList();

  ({int captured, int pending}) counts(String namespace) {
    final row = database.db
        .select(
          '''SELECT
        (SELECT COUNT(*) FROM sms_captured_messages WHERE namespace=?) AS captured,
        (SELECT COUNT(*) FROM sms_intake WHERE namespace=?) AS pending''',
          [namespace, namespace],
        )
        .single;
    return (captured: row['captured'] as int, pending: row['pending'] as int);
  }

  List<SmsIntakeEntry> pending(
    String namespace, {
    int limit = 200,
    bool readyOnly = false,
    bool billingPriority = false,
  }) {
    final today = now();
    final previousStart = DateTime(today.year, today.month - 1);
    final currentStart = DateTime(today.year, today.month);
    final olderStart = DateTime(today.year, today.month - 2);
    return database.db
        .select(
          'SELECT * FROM sms_intake WHERE namespace=?${readyOnly ? ' AND next_attempt<=?' : ''} '
          '${billingPriority ? "ORDER BY CASE WHEN received_at>=? AND received_at<? THEN 0 WHEN received_at>=? AND received_at<? THEN 1 WHEN received_at>=? THEN 2 ELSE 3 END, CASE WHEN lower(body) LIKE '%statement%generated%' OR lower(body) LIKE '%statement%ready%' OR lower(body) LIKE '%statement%available%' OR lower(body) LIKE '%bill%generated%' THEN 0 ELSE 1 END, received_at, id" : 'ORDER BY received_at, id'} LIMIT ?',
          [
            namespace,
            if (readyOnly) today.millisecondsSinceEpoch,
            if (billingPriority) previousStart.millisecondsSinceEpoch,
            if (billingPriority) currentStart.millisecondsSinceEpoch,
            if (billingPriority) olderStart.millisecondsSinceEpoch,
            if (billingPriority) previousStart.millisecondsSinceEpoch,
            if (billingPriority) currentStart.millisecondsSinceEpoch,
            limit,
          ],
        )
        .map(
          (r) => SmsIntakeEntry(
            r['id'] as String,
            QueuedSms(
              sender: r['sender'] as String,
              body: r['body'] as String,
              receivedAt: DateTime.fromMillisecondsSinceEpoch(
                r['received_at'] as int,
              ),
            ),
          ),
        )
        .toList();
  }

  void acknowledge(String ns, String id) {
    database.db.execute('SAVEPOINT sms_ack');
    try {
      database.db.execute(
        'UPDATE sms_captured_messages SET processed=1 WHERE namespace=? AND id=?',
        [ns, id],
      );
      database.db.execute('DELETE FROM sms_intake WHERE namespace=? AND id=?', [
        ns,
        id,
      ]);
      database.db.execute(
        "UPDATE sms_source_decisions SET state='final' WHERE namespace=? AND source_key=?",
        [ns, id],
      );
      database.db.execute('RELEASE SAVEPOINT sms_ack');
    } catch (_) {
      database.db.execute('ROLLBACK TO SAVEPOINT sms_ack');
      database.db.execute('RELEASE SAVEPOINT sms_ack');
      rethrow;
    }
  }

  void failed(String ns, String id) => database.db.execute(
    "UPDATE sms_intake SET next_attempt=? + MIN(1800000,30000 * (1 << MIN(attempts,6))),attempts=attempts+1,last_error='Upload pending' WHERE namespace=? AND id=?",
    [now().millisecondsSinceEpoch, ns, id],
  );
  DateTime? nextRetryAt(String ns) {
    final next =
        database.db.select(
              'SELECT MIN(next_attempt) AS next FROM sms_intake WHERE namespace=?',
              [ns],
            ).single['next']
            as int?;
    return next == null ? null : DateTime.fromMillisecondsSinceEpoch(next);
  }

  void clear(String ns) {
    database.db.execute('DELETE FROM sms_intake WHERE namespace=?', [ns]);
    database.db.execute('DELETE FROM sms_captured_messages WHERE namespace=?', [
      ns,
    ]);
    database.db.execute('DELETE FROM sms_source_decisions WHERE namespace=?', [
      ns,
    ]);
  }
}
