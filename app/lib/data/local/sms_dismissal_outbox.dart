import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'sms_feedback_outbox.dart';

/// Account-scoped, crash-safe retry queue for a Needs Review dismissal.
/// The review item itself is resolved immediately; this only syncs feedback.
class SmsDismissalOutbox {
  final AppDatabase database;
  final String namespace;

  SmsDismissalOutbox(this.database, this.namespace) {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_dismissal_outbox (
        namespace TEXT NOT NULL,
        source_key TEXT NOT NULL,
        payload TEXT NOT NULL,
        queued_at INTEGER NOT NULL,
        PRIMARY KEY(namespace, source_key)
      )
    ''');
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_learning_local_migrations (
        migration_key TEXT PRIMARY KEY,
        applied_at INTEGER NOT NULL
      )
    ''');
    final oldConsentQueue = database.db.select(
      'SELECT 1 FROM sms_learning_local_migrations WHERE migration_key=?',
      ['drop_pre_sms_consent_dismissals_v1'],
    );
    if (oldConsentQueue.isEmpty) {
      // Prior dismissal rows were governed by the unrelated merchant
      // contribution toggle. Never upload them under the new SMS-specific
      // consent.
      database.db.execute('DELETE FROM sms_dismissal_outbox');
      database.db.execute(
        'INSERT INTO sms_learning_local_migrations(migration_key,applied_at) VALUES(?,?)',
        [
          'drop_pre_sms_consent_dismissals_v1',
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    }
  }

  void enqueue(String sourceKey, Map<String, dynamic> payload) {
    final safe = Map<String, dynamic>.from(payload);
    safe['eventId'] ??= const Uuid().v4();
    safe['action'] = 'dismissed';
    safe['resolvedKind'] ??= 'unresolved';
    if (safe['sampleBody'] is String) {
      safe['sampleBody'] = redactSmsLearningPattern(
        safe['sampleBody'] as String,
      );
    }
    if (safe['templateText'] is String) {
      safe['templateText'] = redactSmsLearningPattern(
        safe['templateText'] as String,
      );
    }
    database.db.execute(
      '''INSERT INTO sms_dismissal_outbox(namespace, source_key, payload, queued_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(namespace, source_key) DO UPDATE SET payload=excluded.payload''',
      [
        namespace,
        sourceKey,
        jsonEncode(safe),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  List<Map<String, dynamic>> pending() => database.db
      .select(
        'SELECT source_key,payload FROM sms_dismissal_outbox WHERE namespace=? ORDER BY queued_at',
        [namespace],
      )
      .map((row) {
        final payload =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        if (payload['eventId'] is! String) {
          payload['eventId'] = const Uuid().v4();
          payload['action'] = 'dismissed';
          payload['resolvedKind'] ??= 'unresolved';
          database.db.execute(
            'UPDATE sms_dismissal_outbox SET payload=? WHERE namespace=? AND source_key=?',
            [jsonEncode(payload), namespace, row['source_key']],
          );
        }
        return payload;
      })
      .toList();

  void clear() => database.db.execute(
    'DELETE FROM sms_dismissal_outbox WHERE namespace=?',
    [namespace],
  );

  void acknowledge(String sourceKey, {required String eventId}) {
    final rows = database.db.select(
      'SELECT payload FROM sms_dismissal_outbox WHERE namespace=? AND source_key=?',
      [namespace, sourceKey],
    );
    if (rows.isEmpty) return;
    final payload =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    if (payload['eventId'] != eventId) return;
    database.db.execute(
      'DELETE FROM sms_dismissal_outbox WHERE namespace=? AND source_key=?',
      [namespace, sourceKey],
    );
  }
}
