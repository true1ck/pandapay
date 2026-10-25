import 'dart:convert';

import '../local_sms_parser.dart';
import '../needs_review_repository.dart';
import 'app_database.dart';
import 'auto_resolved_history_repository.dart';
import 'financial_store.dart';
import 'sms_learning_feedback.dart';

/// User actions on a Tier-1 auto-resolution receipt.
///
/// Both operations are deliberately reversible and defensive: the transaction,
/// commitment or review row may already be gone (another flow resolved it, or
/// a server refresh replaced it). A missing row must never crash the screen, so
/// each step is best-effort and the receipt itself is the source of truth.
class SmsAutoResolutionController {
  final AppDatabase database;
  final FinancialStore store;
  final NeedsReviewRepository reviewRepository;
  final String namespace;

  SmsAutoResolutionController({
    required this.database,
    required this.store,
    required this.reviewRepository,
    required this.namespace,
  });

  /// Corrects the category of an auto-filed transaction and teaches the local
  /// rule table so the next message from the same merchant is categorised
  /// instantly.
  Future<void> changeCategory(
    AutoResolvedHistoryEntry entry,
    String categorySlug,
  ) async {
    final slug = categorySlug.trim().toLowerCase();
    if (slug.isEmpty) return;
    store.batch(() {
      AutoResolvedHistoryRepository(
        database,
        namespace: namespace,
      ).updateCategory(entry.id, slug);
      SmsLearningFeedback(
        database,
        namespace: namespace,
      ).recordCategoryCorrection(
        merchantOrPattern: entry.title,
        categorySlug: slug,
      );
      _updateTransactionCategory(entry, slug);
      store.notifyPendingChange(namespace);
    });
  }

  /// Undoes an auto-resolution: removes the auto-filed transaction (or bill),
  /// drops the receipt and puts the message back into Needs Review.
  Future<void> moveToReview(AutoResolvedHistoryEntry entry) async {
    store.batch(() {
      database.db.execute(
        "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' "
        "AND (source_key=? OR id=?)",
        [namespace, entry.sourceKey, 'local-ai:${entry.sourceKey}'],
      );
      if (entry.resolvedKind == 'bill') {
        database.db.execute(
          'DELETE FROM local_commitments WHERE namespace=? AND id=?',
          [namespace, 'commitment:${entry.sourceKey}'],
        );
      }
      AutoResolvedHistoryRepository(database, namespace: namespace).delete(
        entry.id,
      );
      store.notifyPendingChange(namespace);
    });
    final receivedAt =
        DateTime.tryParse(entry.occurredAt) ?? DateTime.now();
    final id = entry.sourceKey.trim().isEmpty ? entry.id : entry.sourceKey;
    await reviewRepository.add(
      NeedsReviewItem(
        id: id,
        sender: entry.sender,
        body: _reviewBody(entry, receivedAt),
        reason: 'moved_from_auto_resolved',
        receivedAt: receivedAt,
        kind: entry.resolvedKind == 'bill'
            ? NeedsReviewKind.commitment
            : NeedsReviewKind.transaction,
      ),
    );
  }

  void _updateTransactionCategory(AutoResolvedHistoryEntry entry, String slug) {
    final rows = database.db.select(
      "SELECT id, payload FROM financial_entities WHERE namespace=? "
      "AND entity='transactions' AND (source_key=? OR id=?)",
      [namespace, entry.sourceKey, 'local-ai:${entry.sourceKey}'],
    );
    for (final row in rows) {
      final raw = row['payload'] as String?;
      if (raw == null) continue;
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      payload['category_id'] = slug;
      payload['category_name'] = LocalSmsParser.categoryDisplayName(slug);
      // A built-in slug has no parent or custom-category identity; keeping a
      // stale parent from a previous guess would double-count the spend.
      payload['parent_category_id'] = null;
      payload['parent_user_category_id'] = null;
      payload['user_category_id'] = null;
      database.db.execute(
        'UPDATE financial_entities SET payload=? WHERE namespace=? '
        "AND entity='transactions' AND id=?",
        [jsonEncode(payload), namespace, row['id']],
      );
    }
  }

  String _reviewBody(AutoResolvedHistoryEntry entry, DateTime receivedAt) {
    final amount = _formatAmount(entry.amountPaise);
    final day = receivedAt.day.toString().padLeft(2, '0');
    final month = receivedAt.month.toString().padLeft(2, '0');
    final when = '$day-$month-${receivedAt.year}';
    // The text has to read like a real alert: the review capture gate only
    // keeps messages with a financial verb, and a bill with a parseable due
    // date would be filed straight back into commitments instead of review.
    final described = entry.resolvedKind == 'bill'
        ? '${entry.title} bill paid: Rs $amount on $when'
        : 'Rs $amount spent at ${entry.title} on $when';
    return '$described (previously auto-categorized by AI).';
  }

  String _formatAmount(int paise) => paise % 100 == 0
      ? '${paise ~/ 100}'
      : (paise / 100).toStringAsFixed(2);
}
