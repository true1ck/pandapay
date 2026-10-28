import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';

import '../local_sms_parser.dart';
import '../needs_review_repository.dart';
import '../past_bill_receipts.dart';
import 'app_database.dart';
import 'auto_resolved_history_repository.dart';
import 'financial_store.dart';
import 'sms_learning_feedback.dart';
import 'sms_feedback_outbox.dart';

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
  final DateTime? smsLearningConsentGrantedAt;

  SmsAutoResolutionController({
    required this.database,
    required this.store,
    required this.reviewRepository,
    required this.namespace,
    this.smsLearningConsentGrantedAt,
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
      _recordFeedback(
        entry,
        action: 'category_changed',
        correctedFields: {'categorySlug': slug},
        correctionKind: 'misclassified_category',
        consentGrantedAt: smsLearningConsentGrantedAt,
      );
      _updateTransactionCategory(entry, slug);
      store.notifyPendingChange(namespace);
    });
  }

  /// Edits the locally filed transaction behind an Auto-Resolved SMS.
  /// These AI-created rows are device-local, so edits must update the local
  /// financial snapshot and receipt together instead of calling the server
  /// transaction API with a synthetic `local-ai:` id.
  Future<void> editTransaction(
    AutoResolvedHistoryEntry entry, {
    required String merchantName,
    required Money amount,
    required DateTime occurredAt,
  }) async {
    if (entry.resolvedKind != 'transaction') {
      throw ArgumentError('Only auto-resolved transactions can be edited.');
    }
    final merchant = merchantName.trim();
    if (merchant.isEmpty) throw ArgumentError('Merchant is required.');
    if (amount.paise <= 0) throw ArgumentError('Amount must be positive.');
    final occurredAtUtc = occurredAt.toUtc();

    store.batch(() {
      final rows = database.db.select(
        "SELECT id, payload FROM financial_entities WHERE namespace=? "
        "AND entity='transactions' AND (source_key=? OR id=?) LIMIT 1",
        [namespace, entry.sourceKey, 'local-ai:${entry.sourceKey}'],
      );
      if (rows.isEmpty) {
        throw StateError(
          'The auto-resolved transaction is no longer available.',
        );
      }
      final row = rows.single;
      final payload =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      payload['amount_inr'] = amount.rupees;
      payload['merchant_name'] = merchant;
      payload['occurred_at'] = occurredAtUtc.toIso8601String();
      database.db.execute(
        "UPDATE financial_entities SET payload=?, observed_at=? "
        "WHERE namespace=? AND entity='transactions' AND id=?",
        [jsonEncode(payload), timestamp, namespace, row['id']],
      );
      _recordFeedback(
        entry,
        action: 'edited',
        consentGrantedAt: smsLearningConsentGrantedAt,
        correctionKind: _editCorrectionKind(entry, merchant, amount,
            occurredAtUtc),
        correctedFields: {
          'merchant': merchant,
          'amountInr': amount.rupees,
          'occurredAt': occurredAtUtc.toIso8601String(),
        },
      );
      database.db.execute(
        'UPDATE local_auto_resolved_history SET title=?, amount_paise=?, '
        'occurred_at=?, is_user_modified=1 WHERE namespace=? AND id=?',
        [
          merchant,
          amount.paise,
          occurredAtUtc.toIso8601String(),
          namespace,
          entry.id,
        ],
      );
      store.notifyPendingChange(namespace);
    });
  }

  /// Undoes an auto-resolution: removes the auto-filed transaction (or bill),
  /// drops the receipt and puts the message back into Needs Review.
  Future<void> moveToReview(AutoResolvedHistoryEntry entry) async {
    store.batch(() {
      _recordFeedback(
        entry,
        action: 'moved_to_review',
        consentGrantedAt: smsLearningConsentGrantedAt,
        // Restoring an AI dismissal says the message was financial; undoing a
        // filed transaction says it was not. They are different claims.
        correctionKind: entry.resolvedKind == 'dismissed'
            ? 'false_dismissal'
            : 'false_transaction',
      );
      if (entry.resolvedKind != 'dismissed') {
        database.db.execute(
          "DELETE FROM financial_entities WHERE namespace=? AND entity='transactions' "
          "AND (source_key=? OR id=?)",
          [namespace, entry.sourceKey, 'local-ai:${entry.sourceKey}'],
        );
      }
      if (entry.resolvedKind == 'bill') {
        database.db.execute(
          'DELETE FROM local_commitments WHERE namespace=? AND id=?',
          [namespace, 'commitment:${entry.sourceKey}'],
        );
        PastBillReceiptRepository(
          database,
          namespace: namespace,
        ).delete('commitment:${entry.sourceKey}');
      }
      AutoResolvedHistoryRepository(
        database,
        namespace: namespace,
      ).delete(entry.id);
      store.notifyPendingChange(namespace);
    });
    final receivedAt = DateTime.tryParse(entry.occurredAt) ?? DateTime.now();
    final id = entry.sourceKey.trim().isEmpty ? entry.id : entry.sourceKey;
    await reviewRepository.add(
      NeedsReviewItem(
        id: id,
        sender: entry.sender,
        // Keep the non-parsable review summary here. Feeding the original bill
        // or mandate SMS back through NeedsReviewRepository.add() can
        // immediately auto-file it again, defeating the user's undo action.
        // The original SMS remains visible on the Auto-Resolved receipt.
        body: entry.resolvedKind == 'dismissed' && entry.sourceBody != null
            ? entry.sourceBody!
            : _reviewBody(entry, receivedAt),
        reason: 'moved_from_auto_resolved',
        receivedAt: receivedAt,
        kind: entry.resolvedKind == 'bill'
            ? NeedsReviewKind.commitment
            : NeedsReviewKind.transaction,
      ),
    );
  }

  /// A positive label is captured only after the user explicitly confirms the
  /// saved AI decision. Repeated taps are idempotent by source and action.
  void confirmDecision(AutoResolvedHistoryEntry entry) {
    store.batch(
      () => _recordFeedback(
        entry,
        action: 'confirmed',
        consentGrantedAt: smsLearningConsentGrantedAt,
      ),
    );
  }

  void _recordFeedback(
    AutoResolvedHistoryEntry entry, {
    required String action,
    required DateTime? consentGrantedAt,
    Map<String, dynamic>? correctedFields,
    String? correctionKind,
  }) {
    if (consentGrantedAt == null || entry.sourceKey.trim().isEmpty) return;
    final fields = <String, dynamic>{
      'merchant': entry.title,
      'amountInr': entry.amountPaise / 100,
      if (entry.categorySlug != null) 'categorySlug': entry.categorySlug,
      'occurredAt': entry.occurredAt,
      if (entry.dueDate != null) 'dueDate': entry.dueDate,
    };
    SmsFeedbackOutbox(database, namespace: namespace).enqueue(
      sourceKey: entry.sourceKey,
      action: action,
      sender: entry.sender,
      resolvedKind: entry.resolvedKind,
      occurredAt: entry.occurredAt,
      consentGrantedAt: consentGrantedAt,
      sampleBody: entry.sourceBody,
      // Every entry on this screen was filed by the AI pipeline; saying so
      // lets a later correction name the decision it is correcting.
      originalDecision: {
        'kind': entry.resolvedKind,
        'origin': 'ai',
        'fields': fields,
      },
      correctedFields: correctedFields,
      correctionKind: correctionKind,
      decisionOrigin: 'ai',
      reason: action == 'moved_to_review' ? 'user_disputed_ai_decision' : null,
    );
  }

  /// Names the field the user actually changed. An edit that touches nothing
  /// the SMS decision produced is presentation-only and must not train.
  String _editCorrectionKind(
    AutoResolvedHistoryEntry entry,
    String merchant,
    Money amount,
    DateTime occurredAtUtc,
  ) {
    if (amount.paise != entry.amountPaise) return 'wrong_amount';
    if (merchant != entry.title) return 'wrong_merchant';
    final original = DateTime.tryParse(entry.occurredAt)?.toUtc();
    if (original != null && original != occurredAtUtc) return 'wrong_date';
    return 'cosmetic';
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

  String _formatAmount(int paise) =>
      paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);
}
