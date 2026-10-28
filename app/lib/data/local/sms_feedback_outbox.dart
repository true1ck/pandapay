import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'app_database.dart';
import '../consents_api.dart';

/// Typed reasons a user can correct an SMS decision. Mirrors the allow-list in
/// `api/src/sms_learning_feedback_route.js`; an unknown value is rejected there.
const List<String> smsCorrectionKinds = [
  'misclassified_category',
  'misclassified_kind',
  'wrong_amount',
  'wrong_merchant',
  'wrong_date',
  'wrong_direction',
  'wrong_instrument',
  'wrong_account',
  'wrong_bill_fields',
  'false_transaction',
  'false_dismissal',
  'duplicate',
  'already_paid',
  'cosmetic',
  'preference_only',
];

/// Kinds that make no claim about classification correctness, so they must not
/// train a shared rule.
const List<String> smsNonTrainingCorrectionKinds = [
  'duplicate',
  'already_paid',
  'cosmetic',
  'preference_only',
];

/// Where the corrected decision came from.
const List<String> smsDecisionOrigins = [
  'parser',
  'downloaded_rule',
  'shared_rule',
  'ai',
  'manual',
];

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
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_learning_after_sync (
        namespace TEXT NOT NULL,
        client_seq INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        acknowledged INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        PRIMARY KEY(namespace, client_seq)
      )
    ''');
  }

  String enqueue({
    String? eventId,
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
    double? aiConfidenceScore,
    String? decisionOrigin,
    String? correctionKind,
    String? decisionRuleId,
    int factIndex = 0,
    DateTime? messageAt,
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
      'ai_auto_resolved',
    };
    if (!actions.contains(action)) throw ArgumentError.value(action, 'action');
    if (correctionKind != null && !smsCorrectionKinds.contains(correctionKind)) {
      throw ArgumentError.value(correctionKind, 'correctionKind');
    }
    if (decisionOrigin != null && !smsDecisionOrigins.contains(decisionOrigin)) {
      throw ArgumentError.value(decisionOrigin, 'decisionOrigin');
    }
    if (factIndex < 0 || factIndex > 31) {
      throw ArgumentError.value(factIndex, 'factIndex');
    }
    final resolvedEventId = eventId ??
        const Uuid().v5(
          '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
          '$namespace:$sourceKey:$factIndex:$action:${jsonEncode({
            'originalDecision': originalDecision,
            'correctedFields': correctedFields ?? const {},
            'correctionKind': correctionKind,
            'reason': reason?.trim().isNotEmpty == true
                ? reason!.trim()
                : null,
            'messageAt': messageAt?.toUtc().toIso8601String(),
          })}',
        );
    final payload = <String, dynamic>{
      'eventId': resolvedEventId,
      'sourceKey': sourceKey,
      'action': action,
      'sender': redactSmsLearningPattern(sender) ?? 'unknown_sender',
      'resolvedKind': resolvedKind,
      'occurredAt': DateTime.parse(occurredAt).toUtc().toIso8601String(),
      'consentPurpose': 'sms_shared_learning',
      'consentPolicyVersion': smsSharedLearningPolicyVersion,
      'consentGrantedAt': consentGrantedAt.toUtc().toIso8601String(),
      'sampleBody': ?redactSmsLearningPattern(sampleBody),
      'originalDecision': ?originalDecision,
      'correctedFields': ?correctedFields,
      'reason': ?(reason?.trim().isNotEmpty == true ? reason!.trim() : null),
      'aiConfidenceScore': ?aiConfidenceScore,
      'decisionOrigin': ?decisionOrigin,
      'correctionKind': ?correctionKind,
      'decisionRuleId': ?decisionRuleId,
      'factIndex': factIndex,
      'messageAt': ?messageAt?.toUtc().toIso8601String(),
    };
    database.db.execute(
      '''INSERT INTO sms_learning_feedback_outbox
         (namespace,event_id,source_key,payload,queued_at)
         VALUES(?,?,?,?,?) ON CONFLICT(namespace,event_id) DO NOTHING''',
      [
        namespace,
        resolvedEventId,
        sourceKey,
        jsonEncode(payload),
        now().millisecondsSinceEpoch,
      ],
    );
    return resolvedEventId;
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

  void clear() {
    database.db.execute(
      'DELETE FROM sms_learning_feedback_outbox WHERE namespace=?',
      [namespace],
    );
    database.db.execute(
      'DELETE FROM sms_learning_after_sync WHERE namespace=?',
      [namespace],
    );
  }

  /// Holds consented SMS correction metadata until its transaction update is
  /// accepted by financial sync. The raw SMS stays in sms_captured_messages.
  void enqueueAfterSync({
    required int clientSeq,
    required Map<String, dynamic> payload,
  }) {
    final sidecar = Map<String, dynamic>.from(payload)
      ..putIfAbsent('eventId', () => const Uuid().v4());
    database.db.execute(
      'INSERT OR REPLACE INTO sms_learning_after_sync '
      '(namespace, client_seq, payload_json, acknowledged, created_at) '
      'VALUES (?, ?, ?, 0, ?)',
      [
        namespace,
        clientSeq,
        jsonEncode(sidecar),
        now().millisecondsSinceEpoch,
      ],
    );
  }

  void acknowledgeAfterSync(int clientSeq) => database.db.execute(
    'UPDATE sms_learning_after_sync SET acknowledged=1 '
    'WHERE namespace=? AND client_seq=?',
    [namespace, clientSeq],
  );

  List<({int clientSeq, Map<String, dynamic> payload})> pendingAfterSync() {
    final rows = database.db.select(
      'SELECT client_seq, payload_json FROM sms_learning_after_sync '
      'WHERE namespace=? AND acknowledged=1 ORDER BY created_at',
      [namespace],
    );
    return rows
        .map((row) => (
          clientSeq: row['client_seq'] as int,
          payload: Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          ),
        ))
        .toList();
  }

  void removeAfterSync(int clientSeq) => database.db.execute(
    'DELETE FROM sms_learning_after_sync WHERE namespace=? AND client_seq=?',
    [namespace, clientSeq],
  );

  int count() =>
      database.db.select(
            'SELECT COUNT(*) AS count FROM sms_learning_feedback_outbox WHERE namespace=?',
            [namespace],
          ).single['count']
          as int;

  /// Returns true when local persisted evidence shows this SMS produced more
  /// than one actionable financial fact. Callers that have no exact fact index
  /// must abstain from shared feedback in that case.
  bool hasMultiplePersistedFacts(String sourceKey) {
    var factCount = 0;
    final hasFinancialEntities = database.db.select(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='financial_entities'",
    ).isNotEmpty;
    if (hasFinancialEntities) {
      final storedRows = database.db.select(
        'SELECT COUNT(*) AS count FROM financial_entities '
        'WHERE namespace=? AND source_key=?',
        [namespace, sourceKey],
      );
      factCount += storedRows.single['count'] as int;
    }
    if (factCount > 1) return true;

    final hasFactsOutbox = database.db.select(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sms_facts_outbox'",
    ).isNotEmpty;
    if (hasFactsOutbox) {
      final rows = database.db.select(
        'SELECT facts FROM sms_facts_outbox WHERE namespace=? AND id=?',
        [namespace, sourceKey],
      );
      for (final row in rows) {
        try {
          final envelope = jsonDecode(row['facts'] as String) as Map;
          final facts = envelope['facts'];
          if (facts is List) factCount += facts.length;
        } catch (_) {
          // Unknown persisted shape cannot establish multiplicity.
        }
      }
    }
    return factCount > 1;
  }
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
    RegExp(
      r'\b(?:Mr\.?|Mrs\.?|Ms\.?|Miss|Shri|Smt\.?|[Cc]ustomer|[Aa]ccount holder|[Cc]ardholder|[Bb]eneficiary|[Rr]ecipient)\s+(?:[Nn]ame\s*[:=-]?\s*)?[A-Z][a-z]{1,30}(?:\s+[A-Z][a-z]{1,30}){0,2}\b',
    ),
    '{name}',
  );
  text = text.replaceAll(
    RegExp(
      r'\b[A-Z][a-z]{2,30}(?:\s+[A-Z][a-z]{2,30}){0,2}\s*,?\s+(?=(?:your\b|you\b|has\b|have\b|payment\b|account\b|card\b|paid\b|spent\b|received\b|debited\b|credited\b|transferred\b|made\b))',
    ),
    '{name} ',
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
