import 'dart:convert';

import '../../data/local/app_database.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/local/sms_learning_feedback.dart';
import '../../data/sms_fact_contract.dart' show smsSpendCategories;
import '../../data/user_cards_repository.dart' show TransactionEntry;

/// Teaches the on-device merchant rule when the user moves an SMS-backed
/// transaction into a canonical spend category.
///
/// This is personal, local-only preference learning: nothing is queued or
/// uploaded. It abstains when the evidence is ambiguous (the same SMS arrived
/// more than once, or produced more than one fact), when the original SMS is
/// no longer on the device, or when the slug is not a canonical category.
/// Never throws: the caller's financial edit has already succeeded.
void recordLocalCategoryCorrection({
  required AppDatabase database,
  required String namespace,
  required TransactionEntry original,
  required String categorySlug,
}) {
  if (original.source != 'sms' && original.source != 'sms_bulk') return;
  final sourceKey = original.sourceKey ?? '';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey)) return;
  final merchant = (original.merchantName ?? '').trim();
  if (merchant.isEmpty) return;
  if (!smsSpendCategories.contains(categorySlug.trim().toLowerCase())) return;
  try {
    final intake = SmsIntakeRepository(database);
    if (intake.hasRepeatedOccurrence(namespace, sourceKey)) return;
    if (_hasMultiplePersistedFacts(database, namespace, sourceKey)) return;
    final captured = intake.capturedById(namespace, sourceKey);
    if (captured == null) return;
    SmsLearningFeedback(database, namespace: namespace)
        .recordCategoryCorrection(
      merchantOrPattern: merchant,
      categorySlug: categorySlug,
      sender: captured.message.sender,
      sampleBody: captured.message.body,
    );
  } catch (_) {
    // A local rule is a convenience; never surface an error for it.
  }
}

/// True when local persisted evidence shows this SMS produced more than one
/// actionable financial fact, so a category change cannot be attributed to a
/// single merchant.
bool _hasMultiplePersistedFacts(
  AppDatabase database,
  String namespace,
  String sourceKey,
) {
  var factCount = 0;
  final hasFinancialEntities = database.db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='financial_entities'",
  ).isNotEmpty;
  if (hasFinancialEntities) {
    factCount += database.db.select(
      'SELECT COUNT(*) AS count FROM financial_entities '
      'WHERE namespace=? AND source_key=?',
      [namespace, sourceKey],
    ).single['count'] as int;
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
