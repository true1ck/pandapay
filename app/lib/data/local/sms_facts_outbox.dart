import 'dart:convert';

import '../../features/sms_import/sms_background_queue.dart';
import '../local_sms_parser.dart';
import '../sms_fact_contract.dart';
import 'app_database.dart';
import 'sms_learning_privacy.dart';

/// SMS intelligence Phase 2: a durable outbox of TYPED FACTS for recognized
/// non-spend financial messages.
///
/// Balance snapshots, autopay mandate life-cycle changes and failed payment
/// attempts currently get terminal `localIgnore` acknowledgements, so the
/// server never learns about them. Instead of storing raw bodies (which the
/// device must not expose), the capture path mints contract-valid facts at
/// capture time and queues only this JSON envelope: source key, sender,
/// occurred time, body hash and the fact set. The flush posts one envelope
/// per message to POST /sms/facts; facts are replay-idempotent by design.
///
/// Facts are derived from the raw body ONCE and the body is never persisted
/// here — the intake repository keeps its own raw copy for the legacy spend
/// pipeline, unchanged.
class SmsFactsOutbox {
  final AppDatabase database;
  final DateTime Function() now;
  SmsFactsOutbox(this.database, {DateTime Function()? now})
    : now = now ?? DateTime.now {
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_facts_outbox (
        namespace TEXT NOT NULL, id TEXT NOT NULL,
        sender TEXT NOT NULL, occurred_at INTEGER NOT NULL,
        facts TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        PRIMARY KEY(namespace, id)
      );
    ''');
    database.db.execute('''
      CREATE TABLE IF NOT EXISTS sms_fact_override_outbox (
        namespace TEXT NOT NULL, source_key TEXT NOT NULL, fact_index INTEGER NOT NULL,
        patch TEXT NOT NULL, reason TEXT, sample_body TEXT, template_text TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        PRIMARY KEY(namespace, source_key, fact_index)
      );
    ''');
    for (final statement in [
      'ALTER TABLE sms_fact_override_outbox ADD COLUMN sample_body TEXT',
      'ALTER TABLE sms_fact_override_outbox ADD COLUMN template_text TEXT',
    ]) {
      try {
        database.db.execute(statement);
      } catch (_) {}
    }
  }

  /// Validates and queues one envelope. Facts are pre-indexed
  /// deterministically so a replay posts the same slots. Invalid facts are
  /// dropped up front — an invalid arrival would be refused server-side
  /// anyway, and abstaining beats posting half-trusted facts.
  void enqueue(
    String namespace,
    QueuedSms message,
    List<SmsFactValidationEntry> facts, {
    required String sourceKey,
  }) {
    final valid = <SmsFactValidationEntry>[];
    for (final fact in facts) {
      final check = validateSmsFact(fact);
      if (check.valid) valid.add(fact);
    }
    if (valid.isEmpty) return;
    final indexed = assignDeterministicSmsFactIndices(valid);
    final bodyHash = smsBodyHash(message.sender, message.body);
    database.db.execute(
      'INSERT OR IGNORE INTO sms_facts_outbox(namespace,id,sender,occurred_at,facts) VALUES (?,?,?,?,?)',
      [
        namespace,
        sourceKey,
        message.sender,
        message.receivedAt.millisecondsSinceEpoch,
        jsonEncode({
          'sourceKey': sourceKey,
          'sender': message.sender,
          'occurredAt': message.receivedAt.toUtc().toIso8601String(),
          'bodyHash': bodyHash,
          'facts': [
            for (final fact in indexed)
              {
                'factIndex': fact.factIndex,
                'factType': fact.factType,
                'payload': fact.payload,
                'provenance': fact.provenance,
              },
          ],
        }),
      ],
    );
  }

  /// One queued envelope. [entries] is the decoded fact list (index,
  /// factType, payload, provenance) ready to POST.
  List<SmsFactsOutboxEntry> pending(
    String namespace, {
    int limit = 50,
  }) => database.db
      .select(
        'SELECT * FROM sms_facts_outbox WHERE namespace=? AND next_attempt<=? '
        'ORDER BY occurred_at, id LIMIT ?',
        [namespace, now().millisecondsSinceEpoch, limit],
      )
      .map((row) {
        final decoded =
            jsonDecode(row['facts'] as String) as Map<String, dynamic>;
        return SmsFactsOutboxEntry(
          row['id'] as String,
          row['sender'] as String,
          decoded,
        );
      })
      .toList();

  void acknowledge(String namespace, String id) {
    database.db.execute(
      'DELETE FROM sms_facts_outbox WHERE namespace=? AND id=?',
      [namespace, id],
    );
  }

  void enqueueOverride(
    String namespace, {
    required String sourceKey,
    required int factIndex,
    required Map<String, dynamic> patch,
    String? reason,
    String? sampleBody,
    String? templateText,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey) ||
        factIndex < 0 ||
        patch.isEmpty) {
      throw ArgumentError('Invalid SMS fact correction');
    }
    database.db.execute(
      '''INSERT INTO sms_fact_override_outbox(namespace,source_key,fact_index,patch,reason,sample_body,template_text)
         VALUES(?,?,?,?,?,?,?) ON CONFLICT(namespace,source_key,fact_index) DO UPDATE SET
           patch=excluded.patch,reason=excluded.reason,sample_body=excluded.sample_body,
           template_text=excluded.template_text,attempts=0,next_attempt=0,last_error=NULL''',
      [
        namespace,
        sourceKey,
        factIndex,
        jsonEncode(patch),
        reason,
        redactSmsLearningText(sampleBody),
        redactSmsLearningText(templateText),
      ],
    );
  }

  List<SmsFactOverrideOutboxEntry> pendingOverrides(
    String namespace, {
    int limit = 50,
  }) => database.db
      .select(
        'SELECT * FROM sms_fact_override_outbox WHERE namespace=? AND next_attempt<=? '
        'ORDER BY rowid LIMIT ?',
        [namespace, now().millisecondsSinceEpoch, limit],
      )
      .map(
        (row) => SmsFactOverrideOutboxEntry(
          sourceKey: row['source_key'] as String,
          factIndex: row['fact_index'] as int,
          patch: jsonDecode(row['patch'] as String) as Map<String, dynamic>,
          reason: row['reason'] as String?,
          sampleBody: row['sample_body'] as String?,
          templateText: row['template_text'] as String?,
        ),
      )
      .toList();

  void acknowledgeOverride(
    String namespace,
    String sourceKey,
    int factIndex,
  ) => database.db.execute(
    'DELETE FROM sms_fact_override_outbox WHERE namespace=? AND source_key=? AND fact_index=?',
    [namespace, sourceKey, factIndex],
  );

  void failedOverride(
    String namespace,
    String sourceKey,
    int factIndex,
  ) => database.db.execute(
    "UPDATE sms_fact_override_outbox SET next_attempt=? + MIN(1800000,30000 * (1 << MIN(attempts,6))),attempts=attempts+1,last_error='Correction sync pending' WHERE namespace=? AND source_key=? AND fact_index=?",
    [now().millisecondsSinceEpoch, namespace, sourceKey, factIndex],
  );

  void failed(String namespace, String id) => database.db.execute(
    "UPDATE sms_facts_outbox SET next_attempt=? + MIN(1800000,30000 * (1 << MIN(attempts,6))),attempts=attempts+1,last_error='Facts upload pending' WHERE namespace=? AND id=?",
    [now().millisecondsSinceEpoch, namespace, id],
  );

  bool contains(String namespace, String id) => database.db.select(
    'SELECT 1 FROM sms_facts_outbox WHERE namespace=? AND id=?',
    [namespace, id],
  ).isNotEmpty;

  void clear(String namespace) {
    database.db.execute('DELETE FROM sms_facts_outbox WHERE namespace=?', [
      namespace,
    ]);
    database.db.execute(
      'DELETE FROM sms_fact_override_outbox WHERE namespace=?',
      [namespace],
    );
  }
}

class SmsFactsOutboxEntry {
  final String id;
  final String sender;
  final Map<String, dynamic> envelope;
  const SmsFactsOutboxEntry(this.id, this.sender, this.envelope);
}

class SmsFactOverrideOutboxEntry {
  final String sourceKey;
  final int factIndex;
  final Map<String, dynamic> patch;
  final String? reason;
  final String? sampleBody;
  final String? templateText;
  const SmsFactOverrideOutboxEntry({
    required this.sourceKey,
    required this.factIndex,
    required this.patch,
    this.reason,
    this.sampleBody,
    this.templateText,
  });
}

/// Device-side specialist that turns a locally classified observation into
/// contract-valid typed facts. Deliberately narrow: only the families Phase 2
/// routes (balance, failed/declined attempts, mandate lifecycle) mint facts;
/// every rule runs against the raw body ONCE here, never persisted.
List<SmsFactValidationEntry> buildSmsFactsForObservation({
  required String body,
  required LocalSmsObservation observation,
  required DateTime receivedAt,
}) {
  final lower = body.toLowerCase();
  final asOfAt = receivedAt.toUtc().toIso8601String();
  final provenance = {
    'parserVersion': LocalSmsParser.version,
    'family': observation.eventType.wireValue,
    'device': true,
  };
  final facts = <SmsFactValidationEntry>[];
  void add(
    String factType,
    Map<String, Object?> payload, {
    Map<String, Object?> provenancePatch = const {},
  }) {
    facts.add(
      SmsFactValidationEntry(
        factType: factType,
        payload: payload,
        provenance: {...provenance, ...provenancePatch},
      ),
    );
  }

  switch (observation.eventType) {
    case LocalSmsEventType.balance:
      final balance = observation.availableBalance;
      if (balance == null || balance.paise < 0) break;
      final isCard = _reMatch(r'\bcredit\s+(?:card|limit)\b', lower);
      final payload = <String, Object?>{
        'availableBalanceInr': balance.rupees,
        'asOfAt': asOfAt,
        'instrument': isCard ? 'credit_card' : 'upi_bank',
        if (isCard && observation.cardLast4 != null)
          'last4': observation.cardLast4,
        if (!isCard && observation.accountLast4 != null)
          'accountLast4': observation.accountLast4,
      };
      add('balance_snapshot', payload);
      break;
    case LocalSmsEventType.failed:
      final isMandate = _reMatch(
        r'\b(?:auto[-\s]?pay|e[-\s]?mandate|mandate)\b',
        lower,
      );
      final isCancel = _reMatch(r'\bcancel(?:led|ed|ling|ing)\b', lower);
      if (isMandate && isCancel) {
        final merchant = _mandateCancelledMerchant(lower);
        if (merchant == null) break;
        add('mandate_lifecycle', {
          'mandateStatus': 'cancelled',
          'asOfAt': asOfAt,
          'merchant': merchant,
          if (observation.cardLast4 != null) 'last4': observation.cardLast4,
          if (observation.accountLast4 != null)
            'accountLast4': observation.accountLast4,
        });
        break;
      }
      final merchant = _attemptMerchant(lower);
      final isCard = _reMatch(r'\bcredit\s+card\b', lower);
      add('pending_or_failed_attempt', {
        'attemptStatus': 'failed',
        'occurredAt': asOfAt,
        'merchant': ?merchant,
        if (isCard && observation.cardLast4 != null)
          'last4': observation.cardLast4,
        if (isCard) 'instrument': 'credit_card',
        if (observation.accountLast4 != null)
          'accountLast4': observation.accountLast4,
      });
      break;
    case LocalSmsEventType.autopay:
      if (_reMatch(r'\bcancel(?:led|ed|ling|ing)\b', lower)) {
        final cancelledMerchant = _mandateCancelledMerchant(lower);
        if (cancelledMerchant != null) {
          add('mandate_lifecycle', {
            'mandateStatus': 'cancelled',
            'asOfAt': asOfAt,
            'merchant': cancelledMerchant,
          });
        }
        break;
      }
      // Registration/mandate lifecycle. A ceiling is optional authorization
      // metadata and must not gate a named service setup fact.
      final limit = observation.autopayLimit;
      final merchant = _mandateRegisteredMerchant(lower) ??
          observation.billerName?.trim();
      if (merchant == null) break;
      final isCard = _reMatch(r'\bcredit\s+card\b', lower);
      final explicitService = _reMatch(
        r'\b(?:subscription|membership)\b',
        lower,
      );
      final targetKind = _reMatch(
        r'\b(?:credit\s+card|card)\s*(?:bill|payment|dues?)\b|\b(?:bill|dues?)\s*(?:of|for|on)?\s*(?:your\s*)?credit\s*card\b',
        lower,
      )
          ? 'card_bill'
          : _reMatch(r'\b(?:electricity|water|gas|utility|municipal)\s*(?:bill|payment|dues?)\b|\b(?:bill|statement|minimum\s+due)\b', lower) &&
                  !explicitService
              ? 'utility_or_other_bill'
              : 'service_merchant';
      add('mandate_lifecycle', {
        'mandateStatus': 'registered',
        'targetKind': targetKind,
        'asOfAt': asOfAt,
        'merchant': merchant,
        if (targetKind == 'service_merchant') ...{
          'serviceName': merchant,
          if (explicitService) ...{
            'explicitSubscription': true,
            'subscriptionEvidence': 'explicit',
          } else
            'subscriptionEvidence': 'historical',
        },
        if (limit != null && limit.paise > 0) ...{
          'amountRole': 'ceiling',
          'limitInr': limit.rupees,
        },
        if (isCard && observation.cardLast4 != null)
          'last4': observation.cardLast4,
        if (!isCard && observation.accountLast4 != null)
          'accountLast4': observation.accountLast4,
      });
      break;
    case LocalSmsEventType.bill:
      // Statement/bill obligations become separate role-scoped facts so the
      // total, minimum and due date never collapse into one money number.
      final due = observation.dueDate;
      if (due == null) break;
      final dueDateIso = due.toUtc().toIso8601String();
      final statementIso = observation.statementDate?.toUtc().toIso8601String();
      final biller = observation.billerName;
      final isCard = _reMatch(r'\bcredit\s+card\b', lower);
      Map<String, Object?> billPayload(String role) => <String, Object?>{
        'amountRole': role,
        'dueDate': dueDateIso,
        'statementDate': ?statementIso,
        'billerName': ?biller,
        if (isCard && observation.cardLast4 != null)
          'last4': observation.cardLast4,
        if (isCard) 'instrument': 'credit_card',
        if (!isCard && observation.accountLast4 != null)
          'accountLast4': observation.accountLast4,
      };
      final total = observation.amountDue;
      if (total == null || total.paise <= 0) break;
      add('bill_obligation', {
        ...billPayload('due_total'),
        'amountDueInr': total.rupees,
      });
      final minimum = observation.minimumDue;
      if (minimum != null && minimum.paise > 0) {
        add('bill_obligation', {
          ...billPayload('due_minimum'),
          'minimumDueInr': minimum.rupees,
        });
      }
      break;
    default:
      break;
  }

  // Multi-fact extraction: an SMS that is primarily a transaction, bill, or attempt
  // can also carry an explicit balance snapshot.
  if (observation.eventType != LocalSmsEventType.balance &&
      observation.availableBalance != null &&
      observation.availableBalance!.paise >= 0) {
    final balance = observation.availableBalance!;
    final isCard = _reMatch(r'\\bcredit\\s+(?:card|limit)\\b', lower);
    final payload = <String, Object?>{
      'availableBalanceInr': balance.rupees,
      'asOfAt': asOfAt,
      'instrument': isCard ? 'credit_card' : 'upi_bank',
      if (isCard && observation.cardLast4 != null)
        'last4': observation.cardLast4,
      if (!isCard && observation.accountLast4 != null)
        'accountLast4': observation.accountLast4,
    };
    add('balance_snapshot', payload);
  }

  return facts;
}

bool _reMatch(String source, String input) => RegExp(source).hasMatch(input);

/// "Your NETFLIX AutoPay mandate has been cancelled successfully on ..."
String? _mandateCancelledMerchant(String lower) {
  final match = RegExp(
    r'(?:your|the)\s+([a-z0-9][a-z0-9&.,\x27\- ]{1,40}?)\s+'
    r'(?:auto[-\s]?pay|e[-\s]?mandate|mandate)\s+'
    r'(?:e[-\s]?)?mandate\s+(?:has\s+been\s+|is\s+)?cancel',
  ).firstMatch(lower);
  if (match == null) {
    // Less wordy form: "Your NETFLIX AutoPay has been cancelled on ...".
    final fallback = RegExp(
      r'(?:your|the)\s+([a-z0-9][a-z0-9&.,\x27\- ]{1,40}?)\s+'
      r'(?:auto[-\s]?pay|e[-\s]?mandate|mandate)\s+'
      r'(?:has\s+been\s+|is\s+)?cancel',
    ).firstMatch(lower);
    if (fallback == null) return null;
    final name = fallback.group(1)?.trim();
    if (name == null || !RegExp(r'[a-z]{3,}').hasMatch(name)) return null;
    return name.toUpperCase();
  }
  final merchant = match.group(1)?.trim();
  if (merchant == null || !RegExp(r'[a-z]{3,}').hasMatch(merchant)) return null;
  return merchant.toUpperCase();
}

/// "AutoPay e-mandate successfully registered for NETFLIX with maximum
/// limit of INR 2,000.00 on HDFC Bank A/c XX1797" — stops before the
/// "with"/"on" clause so the merchant name never swallows the limit phrase.
String? _mandateRegisteredMerchant(String lower) {
  final match = RegExp(
    r'(?:auto[-\s]?pay\s+)?(?:e[-\s]?)?mandate\s+'
    r'(?:has\s+been\s+)?(?:successfully\s+)?registered\s+for\s+'
    r'([a-z0-9][a-z0-9&.,\x27\- ]{1,40}?)'
    r'(?:\s+with\b|\s+on\b|\s*[,.\-:]\s*|$)',
  ).firstMatch(lower);
  if (match == null) return null;
  final merchant = match.group(1)?.trim();
  if (merchant == null || merchant.isEmpty) return null;
  return merchant.toUpperCase();
}

/// "AutoPay payment for NETFLIX Entertainment failed due to ..." — the
/// merchant must be immediately followed by the failure word, so nothing
/// verbose gets swallowed.
String? _attemptMerchant(String lower) {
  final match = RegExp(
    r'(?:payment|autopay)\s+for\s+([a-z0-9][a-z0-9&.,\x27\- ]{1,40}?)\s+failed',
  ).firstMatch(lower);
  if (match == null) return null;
  final merchant = match.group(1)?.trim();
  if (merchant == null || merchant.isEmpty) return null;
  return merchant.toUpperCase();
}
