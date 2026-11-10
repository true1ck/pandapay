import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

class OutboxRecord {
  const OutboxRecord({
    required this.id,
    required this.kind,
    required this.payload,
    required this.attempts,
  });
  final String id;
  final String kind;
  final String payload;
  final int attempts;
  bool get backfill => (jsonDecode(payload) as Map)['_backfill'] == true;
  bool get categoryOnly =>
      (jsonDecode(payload) as Map)['_categoryOnly'] == true;
  Map<String, Object?> get json =>
      (jsonDecode(payload) as Map).cast<String, Object?>()
        ..remove('_backfill')
        ..remove('_categoryOnly');
}

/// A durable account queue. Acknowledgement compares the sent payload so an
/// update made while a request is in flight remains queued.
class OutboxStore {
  OutboxStore(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  void enqueue(
    String kind,
    String id,
    Map<String, Object?> payload, {
    bool backfill = false,
    bool categoryOnly = false,
  }) {
    db.execute(
      '''
INSERT INTO v2_outbox(namespace, id, kind, payload) VALUES (?, ?, ?, ?)
ON CONFLICT(namespace, id) DO UPDATE SET payload=excluded.payload,
  attempts=0, next_attempt_at=0 WHERE v2_outbox.payload != excluded.payload
''',
      [
        namespace,
        '$kind:$id',
        kind,
        jsonEncode({
          ...payload,
          if (backfill) '_backfill': true,
          if (categoryOnly) '_categoryOnly': true,
        }),
      ],
    );
  }

  List<OutboxRecord> due(DateTime now, {int limit = 500}) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    return [
      for (final row in db.select(
        'SELECT id, kind, payload, attempts FROM v2_outbox '
        'WHERE namespace=? AND next_attempt_at<=? ORDER BY rowid LIMIT ?',
        [namespace, now.millisecondsSinceEpoch, limit],
      ))
        OutboxRecord(
          id: row['id'] as String,
          kind: row['kind'] as String,
          payload: row['payload'] as String,
          attempts: row['attempts'] as int,
        ),
    ];
  }

  bool acknowledge(OutboxRecord sent) {
    db.execute(
      'DELETE FROM v2_outbox WHERE namespace=? AND id=? AND payload=?',
      [namespace, sent.id, sent.payload],
    );
    return db.updatedRows != 0;
  }

  /// Schedules another try. [after] overrides the usual back-off, for a server
  /// that said when to come back (HTTP 429 with Retry-After).
  void retry(OutboxRecord sent, DateTime now, {Duration? after}) {
    final seconds =
        after?.inSeconds ??
        (30 * (1 << sent.attempts.clamp(0, 6))).clamp(30, 1800);
    db.execute(
      'UPDATE v2_outbox SET attempts=attempts+1, next_attempt_at=? '
      'WHERE namespace=? AND id=? AND payload=?',
      [
        now.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
        namespace,
        sent.id,
        sent.payload,
      ],
    );
  }
}
