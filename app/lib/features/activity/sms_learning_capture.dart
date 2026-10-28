import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/consents_api.dart' show smsSharedLearningPolicyVersion;
import '../../data/local/response_cache.dart' show ResponseCache;
import '../../data/local/sms_feedback_outbox.dart';
import '../../data/local/sms_intake_repository.dart';
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
  try {
    return await ref.read(smsSharedLearningConsentProvider.future) != null;
  } catch (_) {
    return false;
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
    final consentAt = smsLearningConsentAtCapture(ref);
    if (consentAt == null) return;
    final queue = captureSmsLearningQueueContext(ref);
    final cache = await queue.cacheFuture;
    final captured = SmsIntakeRepository(
      cache.financialStore.database,
    ).capturedById(queue.namespace, sourceKey);
    if (captured == null) return;
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
      originalDecision: originalDecision,
      correctedFields: correctedFields,
      correctionKind: correctionKind,
      decisionOrigin: decisionOrigin,
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
