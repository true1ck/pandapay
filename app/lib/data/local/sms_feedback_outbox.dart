import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'app_database.dart';

/// Durable queue for explicit SMS decision feedback. Events are immutable and
/// keyed independently so retries cannot overwrite a later correction.
class SmsFeedbackOutbox {
  final AppDatabase database;
  final String namespace;
  final DateTime Function() now;

  SmsFeedbackOutbox(
    this.database, {
    required this.namespace,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_learning_feedback_outbox (
        namespace TEXT NOT NULL,
        event_id TEXT NOT NULL,
        source_key TEXT NOT NULL,
        payload TEXT NOT NULL,
        queued_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        PRIMARY KEY(namespace, event_id)
      )
    ''');
    database.db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sms_feedback_pending '
      'ON sms_learning_feedback_outbox(namespace, next_attempt, queued_at)',
    );
  }

  String enqueue({
    required String sourceKey,
    required String action,
    required String sender,
    required String resolvedKind,
    required String occurredAt,
    required DateTime consentGrantedAt,
    String? sampleBody,
    Map<String, dynamic>? originalDecision,
    Map<String, dynamic>? correctedFields,
    String? reason,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey)) {
      throw ArgumentError.value(sourceKey, 'sourceKey', 'Expected SHA-256 hex');
    }
    const actions = {
      'confirmed',
      'edited',
      'category_changed',
      'moved_to_review',
      'dismissed',
    };
    if (!actions.contains(action)) throw ArgumentError.value(action, 'action');
    final eventId = const Uuid().v5(
      '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
      '$namespace:$sourceKey:$action:${jsonEncode(correctedFields ?? const {})}',
    );
    final payload = <String, dynamic>{
      'eventId': eventId,
      'sourceKey': sourceKey,
      'action': action,
      'sender': redactSmsLearningPattern(sender) ?? 'unknown_sender',
      'resolvedKind': resolvedKind,
      'occurredAt': DateTime.parse(occurredAt).toUtc().toIso8601String(),
      'consentPurpose': 'sms_shared_learning',
      'consentPolicyVersion': 'sms-shared-learning-v1',
      'consentGrantedAt': consentGrantedAt.toUtc().toIso8601String(),
      'sampleBody': ?redactSmsLearningPattern(sampleBody),
      'originalDecision': ?originalDecision,
      'correctedFields': ?correctedFields,
      'reason': ?(reason?.trim().isNotEmpty == true ? reason!.trim() : null),
    };
    database.db.execute(
      '''INSERT INTO sms_learning_feedback_outbox
         (namespace,event_id,source_key,payload,queued_at)
         VALUES(?,?,?,?,?) ON CONFLICT(namespace,event_id) DO NOTHING''',
      [
        namespace,
        eventId,
        sourceKey,
        jsonEncode(payload),
        now().millisecondsSinceEpoch,
      ],
    );
    return eventId;
  }

  List<SmsFeedbackOutboxEntry> pending({int limit = 50}) => database.db
      .select(
        'SELECT event_id,source_key,payload FROM sms_learning_feedback_outbox '
        'WHERE namespace=? AND next_attempt<=? ORDER BY queued_at LIMIT ?',
        [namespace, now().millisecondsSinceEpoch, limit],
      )
      .map(
        (row) => SmsFeedbackOutboxEntry(
          eventId: row['event_id'] as String,
          sourceKey: row['source_key'] as String,
          payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
        ),
      )
      .toList(growable: false);

  void acknowledge(String eventId) => database.db.execute(
    'DELETE FROM sms_learning_feedback_outbox WHERE namespace=? AND event_id=?',
    [namespace, eventId],
  );

  void failed(String eventId, {String message = 'Feedback sync pending'}) =>
      database.db.execute(
        'UPDATE sms_learning_feedback_outbox SET '
        'next_attempt=? + MIN(1800000,30000 * (1 << MIN(attempts,6))), '
        'attempts=attempts+1,last_error=? WHERE namespace=? AND event_id=?',
        [
          now().millisecondsSinceEpoch,
          message.length > 120 ? message.substring(0, 120) : message,
          namespace,
          eventId,
        ],
      );

  void clear() => database.db.execute(
    'DELETE FROM sms_learning_feedback_outbox WHERE namespace=?',
    [namespace],
  );

  int count() =>
      database.db.select(
            'SELECT COUNT(*) AS count FROM sms_learning_feedback_outbox WHERE namespace=?',
            [namespace],
          ).single['count']
          as int;
}

/// Sends a generalized pattern, never the complete SMS. All numeric runs are
/// hidden so account, card, reference, date, and exact amount values do not
/// leave the device as sample text. Corrected amount/date fields travel in the
/// separately consented structured feedback object.
String? redactSmsLearningPattern(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  var text = value.trim();
  if (RegExp(
    r'\b(?:otp|one[ .-]?time password|verification (?:code|number)|security code|access code|passcode|pin|cvv)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return null;
  }
  text = text.replaceAll(
    RegExp(r'https?://\S+', caseSensitive: false),
    '{url}',
  );
  text = text.replaceAll(
    RegExp(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'),
    '{email}',
  );
  text = text.replaceAll(
    RegExp(r'(?<!\d)(?:\+?\d[\d\s().-]{7,}\d)(?!\d)'),
    '{phone}',
  );
  text = text.replaceAll(RegExp(r'\d+'), '{n}');
  return text.length <= 1200 ? text : '${text.substring(0, 1200)}…';
}

class SmsFeedbackOutboxEntry {
  final String eventId;
  final String sourceKey;
  final Map<String, dynamic> payload;
  const SmsFeedbackOutboxEntry({
    required this.eventId,
    required this.sourceKey,
    required this.payload,
  });
}
