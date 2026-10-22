import 'dart:convert';

import 'app_database.dart';
import 'sms_learning_privacy.dart';

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
  }

  void enqueue(String sourceKey, Map<String, dynamic> payload) {
    final safe = Map<String, dynamic>.from(payload);
    if (safe['sampleBody'] is String) {
      safe['sampleBody'] = redactSmsLearningText(safe['sampleBody'] as String);
    }
    if (safe['templateText'] is String) {
      safe['templateText'] = redactSmsLearningText(safe['templateText'] as String);
    }
    database.db.execute(
      '''INSERT INTO sms_dismissal_outbox(namespace, source_key, payload, queued_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(namespace, source_key) DO UPDATE SET payload=excluded.payload''',
      [namespace, sourceKey, jsonEncode(safe), DateTime.now().millisecondsSinceEpoch],
    );
  }

  List<Map<String, dynamic>> pending() => database.db
      .select('SELECT payload FROM sms_dismissal_outbox WHERE namespace=? ORDER BY queued_at', [namespace])
      .map((row) => jsonDecode(row['payload'] as String) as Map<String, dynamic>)
      .toList();

  void acknowledge(String sourceKey) => database.db.execute(
        'DELETE FROM sms_dismissal_outbox WHERE namespace=? AND source_key=?',
        [namespace, sourceKey],
      );
}
