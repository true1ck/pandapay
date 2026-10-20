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

/// Append/ack queue, not read/replace. An SMS arriving during an upload is
/// never overwritten by that upload's old copy of the queue. Failed items
/// remain on disk; there is no drop-oldest limit.
class SmsIntakeRepository {
  final AppDatabase database;
  final DateTime Function() now;
  SmsIntakeRepository(this.database, {DateTime Function()? now})
    : now = now ?? DateTime.now {
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
        processed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(namespace, id)
      );
      CREATE INDEX IF NOT EXISTS sms_captured_by_date
        ON sms_captured_messages(namespace,received_at DESC,id);
    ''');
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
  String capture(String namespace, QueuedSms sms) {
    final id = smsSourceKey(namespace, sms.sender, sms.body);
    remember(namespace, sms);
    if (wasProcessed(namespace, id)) return id;
    database.db.execute(
      'INSERT OR IGNORE INTO sms_intake(namespace,id,sender,body,received_at) VALUES (?,?,?,?,?)',
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

  void remember(String namespace, QueuedSms sms) => database.db.execute(
    'INSERT OR IGNORE INTO sms_captured_messages(namespace,id,sender,body,received_at) VALUES (?,?,?,?,?)',
    [
      namespace,
      smsSourceKey(namespace, sms.sender, sms.body),
      sms.sender,
      sms.body,
      sms.receivedAt.millisecondsSinceEpoch,
    ],
  );

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

  bool wasProcessed(String namespace, String id) => database.db.select(
    'SELECT 1 FROM sms_captured_messages WHERE namespace=? AND id=? AND processed=1',
    [namespace, id],
  ).isNotEmpty;

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
  }
}
