import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/consents_api.dart' show smsSharedLearningPolicyVersion;
import '../../data/sms_fact_contract.dart' show smsSpendCategories;
import '../../data/local/response_cache.dart' show ResponseCache;
import '../../data/local/auto_resolved_history_repository.dart';
import '../../data/local/sms_feedback_outbox.dart';
import '../../data/local/sms_intake_repository.dart';
import '../../data/local/sms_learning_feedback.dart';
import '../../data/local/sms_rule_exposure_outbox.dart';
import '../../data/user_cards_repository.dart' show TransactionEntry, UserCardsRepository;

/// Everything a capture site needs to queue one consented SMS-learning
/// correction after its local financial edit has committed.
typedef SmsLearningQueueContext = ({
  Future<ResponseCache> cacheFuture,
  String namespace,
  UserCardsRepository? repository,
  bool online,

  /// Resolves to true when the SMS shared-learning consent (granted AND on
  /// the current policy version) is in force at capture time. Fact-override
  /// uploads await this to decide whether SMS-derived evidence may leave
  /// the device.
  Future<bool> smsLearningConsentActive,
});

/// The consent grant in force at capture time, or null when the purpose is
/// off or on a different policy version. A null return means the correction
/// stays local and nothing is queued.
DateTime? smsLearningConsentAtCapture(WidgetRef ref) {
  final consent = ref.read(smsSharedLearningConsentProvider).valueOrNull;
  if (consent?.granted != true ||
      consent?.policyVersion != smsSharedLearningPolicyVersion) {
    return null;
  }
  return consent!.grantedAt;
}

/// Awaitable capture-time consent check: resolves to true only when the
/// SMS shared-learning consent is granted AND on the current policy
/// version. Unlike [smsLearningConsentAtCapture] this works even when the
/// consent provider has not been watched yet; any lookup failure keeps
/// SMS-derived evidence local.
Future<bool> smsLearningConsentActiveAtCapture(WidgetRef ref) async {
  return await smsLearningConsentGrantAtCapture(ref) != null;
}

/// Resolves the current SMS learning consent, including when its provider is
/// still loading. A null result keeps the evidence local.
Future<DateTime?> smsLearningConsentGrantAtCapture(WidgetRef ref) async {
  try {
    final consent = await ref.read(smsSharedLearningConsentProvider.future);
    if (consent?.granted != true ||
        consent?.policyVersion != smsSharedLearningPolicyVersion) {
      return null;
    }
    return consent!.grantedAt;
  } catch (_) {
    return null;
  }
}

SmsLearningQueueContext captureSmsLearningQueueContext(WidgetRef ref) => (
  cacheFuture: ref.read(responseCacheProvider.future),
  namespace: ref.read(cacheNamespaceProvider),
  repository: ref.read(userCardsRepositoryProvider),
  online: ref.read(isOnlineProvider).valueOrNull != false,
  smsLearningConsentActive: smsLearningConsentActiveAtCapture(ref),
);

/// Resolves consent and the captured SMS for `sourceKey`, then enqueues one
/// learning event. Stays local when consent is off or the SMS is not on the
/// device — without the original SMS the correction has no sender, and a
/// placeholder sender would poison the sender-level aggregates. `occurredAtIso`
/// anchors the fact being corrected. Never throws: the caller's financial
/// edit has already succeeded.
Future<void> queueSmsLearningEvent({
  required WidgetRef ref,
  required String sourceKey,
  required String action,
  required String resolvedKind,
  required String occurredAtIso,
  Map<String, dynamic>? originalDecision,
  Map<String, dynamic>? correctedFields,
  String? correctionKind,
  String? reason,
  String? decisionOrigin,
  int factIndex = 0,
}) async {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey)) return;
  try {
    // Read provider-owned dependencies while the screen is still mounted.
    // The consent request can finish after navigation disposes its WidgetRef.
    final consentFuture = ref.read(smsSharedLearningConsentProvider.future);
    final queue = captureSmsLearningQueueContext(ref);
    final cache = await queue.cacheFuture;
    final intake = SmsIntakeRepository(cache.financialStore.database);
    final captured = intake.capturedById(queue.namespace, sourceKey);
    if (captured == null) return;
    final correctedSlug = correctedFields?['categorySlug'];
    final originalMerchant = originalDecision?['fields'] is Map
        ? (originalDecision!['fields'] as Map)['merchant']
        : null;
    if (correctionKind == 'misclassified_category' &&
        correctedSlug is String &&
        smsSpendCategories.contains(correctedSlug.trim().toLowerCase()) &&
        originalMerchant is String &&
        originalMerchant.trim().isNotEmpty) {
      SmsLearningFeedback(
        cache.financialStore.database,
        namespace: queue.namespace,
      ).recordCategoryCorrection(
        merchantOrPattern: originalMerchant,
        categorySlug: correctedSlug,
        sender: captured.message.sender,
        sampleBody: captured.message.body,
      );
    }
    // The ledger intentionally collapses identical sender/body messages to
    // one local source. If that source was observed at distinct delivery times,
    // retain the user's local correction but do not attribute it to a shared
    // learning example for an arbitrary occurrence.
    if (intake.hasRepeatedOccurrence(queue.namespace, sourceKey)) return;
    final consent = await consentFuture;
    final consentAt = consent?.granted == true &&
            consent?.policyVersion == smsSharedLearningPolicyVersion
        ? consent!.grantedAt
        : null;
    if (consentAt == null) return;
    // Only a parser-declared decision can be re-attributed. `ai`, `manual`,
    // `downloaded_rule` and `shared_rule` are asserted by the surface that
    // actually made the call, and overwriting them would blame a shared
    // candidate that was never involved. The candidate must also have produced
    // the fact being corrected, not merely some fact in the same message.
    final correctedFamily = originalDecision?['kind'];
    final candidateId = decisionOrigin == 'parser'
        ? SmsRuleExposureOutbox(cache.financialStore.database)
              .appliedCandidateForFact(
                queue.namespace,
                sourceKey,
                family: correctedFamily is String ? correctedFamily : null,
              )
        : null;
    final effectiveOrigin = candidateId == null
        ? decisionOrigin
        : 'shared_rule';
    final effectiveOriginal = originalDecision == null
        ? null
        : <String, dynamic>{
            ...originalDecision,
            if (candidateId != null) 'origin': 'shared_rule',
            'ruleId': ?candidateId,
          };
    SmsFeedbackOutbox(
      cache.financialStore.database,
      namespace: queue.namespace,
    ).enqueue(
      sourceKey: sourceKey,
      action: action,
      sender: captured.message.sender,
      resolvedKind: resolvedKind,
      occurredAt: occurredAtIso,
      consentGrantedAt: consentAt,
      sampleBody: captured.message.body,
      originalDecision: effectiveOriginal,
      correctedFields: correctedFields,
      correctionKind: correctionKind,
      decisionOrigin: effectiveOrigin,
      decisionRuleId: candidateId,
      reason: reason,
      messageAt: captured.message.receivedAt,
      factIndex: factIndex,
    );
    if (queue.online) {
      unawaited(
        queue.repository
            ?.flushSmsLearningFeedbackQueue()
            .catchError((Object _) => 0),
      );
    }
  } catch (_) {
    // The financial edit already succeeded; learning evidence must never
    // surface an error for it.
  }
}

/// Queues one consented `edited`/`category_changed` correction for an
/// SMS-backed transaction after its local financial edit has committed.
/// Stays local when the transaction is not SMS-backed, the source key is not
/// a SHA-256 hex, consent is off, or the original SMS is not on the device.
/// `correctedFields` must already carry privacy-safe values (canonical slugs,
/// no identifiers).
Future<void> queueSmsTransactionCorrection({
  required WidgetRef ref,
  required TransactionEntry original,
  required String action,
  required Map<String, dynamic> correctedFields,
  required String correctionKind,
  String? reason,
  int factIndex = 0,
}) async {
  if (original.source != 'sms' && original.source != 'sms_bulk') return;
  final sourceKey = original.sourceKey ?? '';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey)) return;
  try {
    final cache = await ref.read(responseCacheProvider.future);
    final feedbackOutbox = SmsFeedbackOutbox(
      cache.financialStore.database,
      namespace: ref.read(cacheNamespaceProvider),
    );
    if (SmsIntakeRepository(cache.financialStore.database)
        .hasRepeatedOccurrence(ref.read(cacheNamespaceProvider), sourceKey)) {
      return;
    }
    if (original.id.startsWith('local-ai:')) {
      final history = AutoResolvedHistoryRepository(
        cache.financialStore.database,
        namespace: ref.read(cacheNamespaceProvider),
      ).findById('ai:$sourceKey');
      if (history?.factIndex == null) return;
      factIndex = history!.factIndex!;
    } else if (feedbackOutbox.hasMultiplePersistedFacts(sourceKey)) {
      return;
    }
  } catch (_) {
    // If the local source index is unavailable, retain the financial edit and
    // abstain from shared learning rather than assign it to fact zero.
    return;
  }
  final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
  String? slugFor(String? id) {
    for (final category in categories) {
      if (category.id == id) return category.slug;
    }
    return null;
  }

  await queueSmsLearningEvent(
    ref: ref,
    sourceKey: sourceKey,
    action: action,
    resolvedKind: 'transaction',
    occurredAtIso: original.occurredAt.toUtc().toIso8601String(),
    originalDecision: {
      'kind': 'posted_movement',
      'origin': original.id.startsWith('local-ai:') ? 'ai' : 'parser',
      'fields': {
        'amountInr': original.amount.rupees,
        'occurredAt': original.occurredAt.toUtc().toIso8601String(),
        if ((original.merchantName ?? '').trim().isNotEmpty)
          'merchant': original.merchantName!.trim(),
        if (slugFor(original.categoryId) != null)
          'categorySlug': slugFor(original.categoryId),
        if (original.instrumentKnown)
          'instrument': original.instrument.wireValue,
        'entryKind': original.entryKind.wireValue,
      },
    },
    correctedFields: correctedFields,
    correctionKind: correctionKind,
    reason: reason,
    decisionOrigin: original.id.startsWith('local-ai:') ? 'ai' : 'parser',
    factIndex: factIndex,
  );
}
